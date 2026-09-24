<?php
/**
 * Writes production's table sizes and a schema dump with the rows setup:upgrade reads, never customer, order
 * or catalogue rows, for the lock rehearsal: `<release> <stats.json> <dump.sql> [<extra-table> ...]`.
 */

declare(strict_types=1);

const SEED_TABLES = [
    'setup_module', 'patch_list', 'store', 'store_group', 'store_website', 'core_config_data',
    'eav_entity_type', 'eav_attribute', 'eav_attribute_set', 'eav_attribute_group', 'eav_entity_attribute',
    'eav_attribute_label', 'eav_attribute_option', 'eav_attribute_option_value', 'eav_form_type',
    'eav_form_type_entity', 'eav_form_fieldset', 'eav_form_fieldset_label', 'eav_form_element',
    'catalog_eav_attribute', 'customer_eav_attribute', 'customer_eav_attribute_website', 'customer_form_attribute',
    'customer_group', 'tax_class', 'theme', 'directory_country', 'directory_country_region',
    'directory_country_region_name', 'indexer_state', 'mview_state', 'flag', 'authorization_role',
    'authorization_rule',
];

function fail(string $message, int $code = 65): never
{
    fwrite(STDERR, $message . "\n");
    exit($code);
}

[, $release, $statsFile, $dumpFile] = array_pad($argv, 4, null);
if (!$release || !$statsFile || !$dumpFile) {
    fail('usage: php magento-db-snapshot.php <release-dir> <stats.json> <dump.sql> [<extra-table> ...]', 64);
}
$env = include rtrim($release, '/') . '/app/etc/env.php';
$db = $env['db']['connection']['default'] ?? fail('no db/connection/default in env.php');
$prefix = (string) ($env['db']['table_prefix'] ?? '');

$host = (string) ($db['host'] ?? 'localhost');
$socket = str_starts_with($host, '/') ? $host : null;
$port = null;
if (!$socket && preg_match('/^(.+):(\d+)$/', $host, $parts)) {
    [$host, $port] = [$parts[1], $parts[2]];
}
$dsn = $socket
    ? sprintf('mysql:unix_socket=%s;dbname=%s', $socket, $db['dbname'])
    : sprintf('mysql:host=%s;%sdbname=%s', $host, $port ? "port=$port;" : '', $db['dbname']);
$options = (array) ($db['driver_options'] ?? []);
$options[PDO::ATTR_ERRMODE] = PDO::ERRMODE_EXCEPTION;
$pdo = new PDO($dsn, (string) $db['username'], (string) ($db['password'] ?? ''), $options);

$tables = [];
$rows = $pdo->query(
    'SELECT TABLE_NAME, TABLE_ROWS, DATA_LENGTH + INDEX_LENGTH, ROW_FORMAT FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = \'BASE TABLE\''
)->fetchAll(PDO::FETCH_NUM);
foreach ($rows as [$name, $count, $bytes, $format]) {
    $tables[$name] = ['rows' => (int) $count, 'bytes' => (int) $bytes, 'row_format' => $format];
}
$stats = [
    'version' => (string) $pdo->query('SELECT VERSION()')->fetchColumn(),
    'row_format' => strtolower((string) $pdo->query('SELECT @@innodb_default_row_format')->fetchColumn()),
    'tables' => $tables,
];
file_put_contents($statsFile, json_encode($stats, JSON_THROW_ON_ERROR | JSON_PRETTY_PRINT));

$dumper = trim((string) shell_exec('command -v mariadb-dump || command -v mysqldump'));
if ($dumper === '') {
    fail('neither mariadb-dump nor mysqldump is installed on this host', 69);
}
$optionFile = tempnam(sys_get_temp_dir(), 'snapshot-');
chmod($optionFile, 0600);
file_put_contents($optionFile, implode("\n", array_filter([
    '[client]',
    'user=' . $db['username'],
    'password="' . addcslashes((string) ($db['password'] ?? ''), "\"\\") . '"',
    $socket ? 'socket=' . $socket : 'host=' . $host,
    $port ? 'port=' . $port : null,
])) . "\n");

$seed = array_values(array_intersect(
    array_map(static fn (string $t): string => $prefix . $t, array_merge(SEED_TABLES, array_slice($argv, 4))),
    array_keys($tables)
));
// --defaults-file, not --defaults-extra-file: a ~/.my.cnf on this host must not
// add a password or a host of its own.
$common = ["--defaults-file=$optionFile", '--single-transaction', '--skip-lock-tables',
    '--no-tablespaces', '--skip-comments', '--hex-blob'];
// MySQL's own mysqldump asks for column statistics, which MariaDB does not have.
if (!str_contains((string) shell_exec(escapeshellarg($dumper) . ' --version'), 'MariaDB')) {
    $common[] = '--column-statistics=0';
}

// Append mode, because the two dumps below share this handle and a child
// process does not advance the parent's offset.
umask(0077);
file_put_contents($dumpFile, '');
$out = fopen($dumpFile, 'ab');
$run = static function (array $arguments) use ($dumper, $out): void {
    $process = proc_open(array_merge([$dumper], $arguments), [1 => $out, 2 => ['pipe', 'w']], $pipes);
    $errors = stream_get_contents($pipes[2]);
    if (proc_close($process) !== 0) {
        fail("the dump failed: $errors");
    }
};
try {
    $run(array_merge($common, ['--no-data', '--triggers', '--routines', $db['dbname']]));
    if ($seed !== []) {
        $run(array_merge($common, ['--no-create-info', '--skip-triggers', $db['dbname']], $seed));
    }
} finally {
    fclose($out);
    unlink($optionFile);
}
chmod($dumpFile, 0600);
echo json_encode(['tables' => count($tables), 'seeded' => count($seed), 'version' => $stats['version']]), "\n";
