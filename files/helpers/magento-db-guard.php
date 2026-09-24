<?php
/**
 * Reads what the database has gained since a release went live (patches, NOT NULL columns, unique and foreign
 * keys), for the rollback guard and the upgrade gate, using only env.php's credentials so no cache is touched: `mark <release>`, `check <release> <mark-json>
 * [<live-release>]` or `themes <release>`, each printing JSON.
 */

declare(strict_types=1);

function fail(string $message, int $code = 65): never
{
    fwrite(STDERR, $message . "\n");
    exit($code);
}

/** @return array{PDO, string} the connection and the table prefix */
function connect(string $release): array
{
    $envFile = $release . '/app/etc/env.php';
    if (!is_file($envFile)) {
        fail("no app/etc/env.php in $release", 66);
    }
    $env = include $envFile;
    $db = $env['db']['connection']['default'] ?? null;
    if (!is_array($db)) {
        fail("no db/connection/default in $envFile");
    }
    $host = (string) ($db['host'] ?? 'localhost');
    if (str_starts_with($host, '/')) {
        $dsn = sprintf('mysql:unix_socket=%s;dbname=%s', $host, $db['dbname']);
    } elseif (preg_match('/^(.+):(\d+)$/', $host, $parts)) {
        $dsn = sprintf('mysql:host=%s;port=%s;dbname=%s', $parts[1], $parts[2], $db['dbname']);
    } else {
        $dsn = sprintf('mysql:host=%s;dbname=%s', $host, $db['dbname']);
    }
    $options = (array) ($db['driver_options'] ?? []);
    $options[PDO::ATTR_ERRMODE] = PDO::ERRMODE_EXCEPTION;
    $pdo = new PDO($dsn, (string) $db['username'], (string) ($db['password'] ?? ''), $options);

    $prefix = (string) ($env['db']['table_prefix'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_]{0,32}$/D', $prefix)) {
        fail("the table prefix in $envFile is not a plain identifier");
    }

    return [$pdo, $prefix];
}

/** A table name with the prefix, which connect() has already checked is a plain identifier. */
function table(string $prefix, string $name): string
{
    return '`' . $prefix . $name . '`';
}

/** @return list<array<int, mixed>> every row of a query that takes no values */
function rows(PDO $pdo, string $sql): array
{
    $statement = $pdo->prepare($sql);
    $statement->execute();

    return $statement->fetchAll(PDO::FETCH_NUM);
}

/** @return list<string> paths of db_schema.xml files, relative to the release */
function schemaFiles(string $release): array
{
    return array_merge(
        glob($release . '/app/code/*/*/etc/db_schema.xml') ?: [],
        glob($release . '/vendor/*/*/etc/db_schema.xml') ?: []
    );
}

/**
 * @return array{columns: array<string, array<string, true>>, constraints: array<string, true>} the columns the
 *     release declares by prefixed table name, and its unique and foreign-key constraints as constraintKey() keys
 */
function declaredSchema(string $release, string $prefix): array
{
    $columns = [];
    $constraints = [];
    foreach (schemaFiles($release) as $file) {
        $xml = simplexml_load_file($file);
        if ($xml === false) {
            fail("cannot parse $file");
        }
        foreach ($xml->table as $table) {
            if ((string) $table['disabled'] === 'true') {
                continue;
            }
            $name = $prefix . (string) $table['name'];
            $columns[$name] ??= [];
            foreach ($table->column as $column) {
                if ((string) $column['disabled'] !== 'true') {
                    $columns[$name][(string) $column['name']] = true;
                }
            }
            foreach ($table->constraint as $constraint) {
                $type = (string) $constraint->attributes('xsi', true)->type;
                if ((string) $constraint['disabled'] === 'true') {
                    continue;
                }
                if ($type === 'unique') {
                    $names = [];
                    foreach ($constraint->column as $column) {
                        $names[] = (string) $column['name'];
                    }
                    $constraints[constraintKey('UNIQUE', $name, $names)] = true;
                } elseif ($type === 'foreign') {
                    $constraints[constraintKey('FOREIGN KEY', $name, [(string) $constraint['column']],
                        $prefix . (string) $constraint['referenceTable'], (string) $constraint['referenceColumn'])] = true;
                }
            }
        }
    }

    return ['columns' => $columns, 'constraints' => $constraints];
}

/** How a unique or foreign-key constraint is named in the report: by its columns, never by its name. */
function constraintKey(string $type, string $table, array $columns, string $refTable = '', string $refColumn = ''): string
{
    return $type === 'UNIQUE'
        ? "UNIQUE $table(" . implode(',', $columns) . ')'
        : "FOREIGN KEY $table(" . implode(',', $columns) . ") -> $refTable($refColumn)";
}

/** @return list<string> the release's recurring setup scripts, relative to it */
function recurringScripts(string $release): array
{
    $found = [];
    foreach (['app/code/*/*/Setup', 'vendor/*/*/Setup'] as $pattern) {
        foreach (['Recurring.php', 'RecurringData.php'] as $name) {
            foreach (glob($release . '/' . $pattern . '/' . $name) ?: [] as $file) {
                $found[] = substr($file, strlen($release) + 1);
            }
        }
    }
    sort($found);

    return $found;
}

/** @return list<string> patch class names in the release's code */
function patchClasses(string $release): array
{
    $classes = [];
    foreach (['app/code/*/*/Setup/Patch/*/*.php', 'vendor/*/*/Setup/Patch/*/*.php'] as $pattern) {
        foreach (glob($release . '/' . $pattern) ?: [] as $file) {
            $source = (string) file_get_contents($file);
            if (preg_match('/^namespace\s+([^;]+);/m', $source, $namespace)) {
                $classes[] = trim($namespace[1]) . '\\' . basename($file, '.php');
            }
        }
    }

    return $classes;
}

/** @return list<string> area/Vendor/name of every theme the release's code registers */
function codeThemes(string $release): array
{
    $themes = [];
    foreach (['app/design/*/*/*/registration.php', 'vendor/*/*/registration.php'] as $pattern) {
        foreach (glob($release . '/' . $pattern) ?: [] as $file) {
            $source = (string) file_get_contents($file);
            if (preg_match('/ComponentRegistrar::THEME\s*,\s*[\'"]([^\'"]+)[\'"]/', $source, $match)) {
                $themes[] = $match[1];
            }
        }
    }
    sort($themes);

    return array_values(array_unique($themes));
}

/** @return array<string, string> every unique and foreign-key constraint as constraintKey(), to its table */
function currentConstraints(PDO $pdo): array
{
    $grouped = [];
    foreach (rows($pdo, "SELECT tc.TABLE_NAME, tc.CONSTRAINT_NAME, tc.CONSTRAINT_TYPE, k.COLUMN_NAME,
            k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME
          FROM information_schema.TABLE_CONSTRAINTS tc
          JOIN information_schema.KEY_COLUMN_USAGE k
            ON k.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND k.TABLE_NAME = tc.TABLE_NAME
           AND k.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
         WHERE tc.CONSTRAINT_SCHEMA = DATABASE() AND tc.CONSTRAINT_TYPE IN ('UNIQUE', 'FOREIGN KEY')
         ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_NAME, k.ORDINAL_POSITION") as $row) {
        [$table, $name, $type, $column, $refTable, $refColumn] = $row;
        $id = $table . "\0" . $name;
        $grouped[$id] ??= ['table' => $table, 'type' => $type, 'columns' => [],
            'ref' => [(string) $refTable, (string) $refColumn]];
        $grouped[$id]['columns'][] = $column;
    }
    $keys = [];
    foreach ($grouped as $constraint) {
        $keys[constraintKey($constraint['type'], $constraint['table'], $constraint['columns'], ...$constraint['ref'])]
            = $constraint['table'];
    }

    return $keys;
}

/** A short hash of a constraint key, which keeps a mark small enough to pass on a command line. */
function constraintHash(string $key): string
{
    return substr(hash('sha256', $key), 0, 16);
}

[, $mode, $release] = array_pad($argv, 3, null);
$release = rtrim((string) $release, '/');
if (!in_array($mode, ['mark', 'check', 'themes'], true) || $release === '') {
    fail('usage: php magento-db-guard.php mark <release-dir> | check <release-dir> <mark-json> [<live-release-dir>]'
        . ' | themes <release-dir>', 64);
}
[$pdo, $prefix] = connect($release);

if ($mode === 'themes') {
    $registered = array_flip(array_map(
        static fn (array $row): string => $row[0] . '/' . $row[1],
        rows($pdo, 'SELECT area, theme_path FROM ' . table($prefix, 'theme'))
    ));
    $missing = array_values(array_filter(codeThemes($release), static fn (string $t): bool => !isset($registered[$t])));
    echo json_encode(['missing' => $missing], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES), "\n";
    exit(0);
}

if ($mode === 'mark') {
    $patchId = (int) rows($pdo, 'SELECT COALESCE(MAX(patch_id), 0) FROM ' . table($prefix, 'patch_list'))[0][0];
    // NOW(), not UTC_TIMESTAMP(): updated_at is a TIMESTAMP, shown in the session's time zone.
    $now = (string) rows($pdo, 'SELECT NOW()')[0][0];
    $constraints = array_map('constraintHash', array_keys(currentConstraints($pdo)));
    sort($constraints);
    echo json_encode(['patch_id' => $patchId, 'recorded_at' => $now, 'constraints' => $constraints],
        JSON_THROW_ON_ERROR), "\n";
    exit(0);
}

$mark = json_decode((string) ($argv[3] ?? ''), true);
if (!is_array($mark)) {
    fail('the mark must be JSON, "{}" for none', 64);
}
$live = isset($argv[4]) ? rtrim($argv[4], '/') : '';

if (isset($mark['patch_id'])) {
    $statement = $pdo->prepare('SELECT patch_name FROM ' . table($prefix, 'patch_list') . ' WHERE patch_id > ? ORDER BY patch_id');
    $statement->execute([(int) $mark['patch_id']]);
    $patchesAfter = $statement->fetchAll(PDO::FETCH_COLUMN);
} else {
    $known = array_flip(patchClasses($release));
    $patchesAfter = array_values(array_filter(
        array_column(rows($pdo, 'SELECT patch_name FROM ' . table($prefix, 'patch_list') . ' ORDER BY patch_id'), 0),
        static fn (string $name): bool => !isset($known[$name])
    ));
}

$schema = declaredSchema($release, $prefix);
$declared = $schema['columns'];
$undeclaredNotNull = [];
foreach (rows($pdo, "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND IS_NULLABLE = 'NO'
        AND COLUMN_DEFAULT IS NULL
        AND EXTRA NOT LIKE '%auto_increment%' AND EXTRA NOT LIKE '%GENERATED%'
      ORDER BY TABLE_NAME, ORDINAL_POSITION") as [$table, $column]) {
    if (isset($declared[$table]) && !isset($declared[$table][$column])) {
        $undeclaredNotNull[] = $table . '.' . $column;
    }
}

// Unique and foreign-key constraints on tables the release declares that were added since its mark: its
// writes know nothing of them, so an INSERT can break on one. With no mark, those it does not declare.
$markConstraints = isset($mark['constraints']) ? array_flip((array) $mark['constraints']) : null;
$undeclaredConstraints = [];
foreach (currentConstraints($pdo) as $key => $table) {
    if (!isset($declared[$table])) {
        continue;
    }
    $added = $markConstraints !== null
        ? !isset($markConstraints[constraintHash($key)])
        : !isset($schema['constraints'][$key]);
    if ($added) {
        $undeclaredConstraints[] = $key;
    }
}

$recurringMissing = $live === '' ? [] : array_values(array_diff(recurringScripts($live), recurringScripts($release)));

$configChanged = null;
if (isset($mark['recorded_at'])) {
    $statement = $pdo->prepare('SELECT COUNT(*) FROM ' . table($prefix, 'core_config_data') . ' WHERE updated_at >= ?');
    $statement->execute([$mark['recorded_at']]);
    $configChanged = (int) $statement->fetchColumn();
}

echo json_encode([
    'patches_after' => $patchesAfter,
    'undeclared_not_null' => $undeclaredNotNull,
    'undeclared_constraints' => $undeclaredConstraints,
    'recurring_missing' => $recurringMissing,
    'config_changed' => $configChanged,
], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES), "\n";
