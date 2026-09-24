<?php
/**
 * Runs one bin/magento command in a release with a private file cache, removed afterwards, so it cannot write
 * into the cache the live release reads: `<release> [--require-isolation] -- <arguments>`. When the first argument
 * is a PHP file, that script runs in the release instead of bin/magento.
 */

declare(strict_types=1);

const EXIT_CANNOT_ISOLATE = 3;

$args = array_slice($argv, 1);
$separator = array_search('--', $args, true);
if ($separator === false || $separator < 1) {
    fwrite(STDERR, "usage: php magento-isolated.php <release-dir> [--require-isolation] -- <bin/magento arguments>\n");
    exit(64);
}
$options = array_slice($args, 0, $separator);
$command = array_slice($args, $separator + 1);
$release = rtrim(array_shift($options), '/');
$requireIsolation = in_array('--require-isolation', $options, true);

if (!is_file($release . '/bin/magento')) {
    fwrite(STDERR, "not a Magento release: $release\n");
    exit(66);
}

$frameworkFiles = [
    $release . '/vendor/magento/framework/App/DeploymentConfig.php',
    $release . '/lib/internal/Magento/Framework/App/DeploymentConfig.php',
];
$supportsOverride = false;
foreach ($frameworkFiles as $file) {
    if (is_file($file) && str_contains((string) file_get_contents($file), 'MAGENTO_DC__OVERRIDE')) {
        $supportsOverride = true;
        break;
    }
}

$cacheDir = null;
$environment = getenv();
if ($supportsOverride) {
    $cacheDir = sys_get_temp_dir() . '/magento-isolated-' . bin2hex(random_bytes(6));
    $frontend = static fn (string $name): array => [
        'backend' => 'Cm_Cache_Backend_File',
        'backend_options' => ['cache_dir' => $cacheDir . '/' . $name],
    ];
    $environment['MAGENTO_DC__OVERRIDE'] = json_encode(
        ['cache' => ['frontend' => ['default' => $frontend('default'), 'page_cache' => $frontend('page_cache')]]],
        JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES
    );
} elseif ($requireIsolation) {
    fwrite(STDERR, "this Magento has no MAGENTO_DC__OVERRIDE, so the command would write into the live cache; not run\n");
    exit(EXIT_CANNOT_ISOLATE);
} else {
    fwrite(STDERR, "warning: this Magento has no MAGENTO_DC__OVERRIDE; running against the shared cache\n");
}

$entry = isset($command[0]) && str_ends_with($command[0], '.php') && is_file($command[0])
    ? [array_shift($command)]
    : ['bin/magento'];
$process = proc_open(
    array_merge([PHP_BINARY], $entry, $command),
    [0 => STDIN, 1 => STDOUT, 2 => STDERR],
    $pipes,
    $release,
    $environment
);
$exitCode = is_resource($process) ? proc_close($process) : 70;

if ($cacheDir !== null && is_dir($cacheDir)) {
    $files = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($cacheDir, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($files as $file) {
        $file->isDir() ? rmdir($file->getPathname()) : unlink($file->getPathname());
    }
    rmdir($cacheDir);
}

exit($exitCode);
