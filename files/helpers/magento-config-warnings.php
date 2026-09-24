<?php
/**
 * Prints, as JSON, what `app:config:import` would warn about before importing this release's config.php, so a
 * deletion is caught before setup:upgrade, which runs with --no-interaction and would answer every warning yes.
 */

declare(strict_types=1);

use Magento\Deploy\Model\DeploymentConfig\ChangeDetector;
use Magento\Deploy\Model\DeploymentConfig\ImporterFactory;
use Magento\Deploy\Model\DeploymentConfig\ImporterPool;
use Magento\Framework\App\Bootstrap;
use Magento\Framework\App\DeploymentConfig;

require getcwd() . '/app/bootstrap.php';

$objectManager = Bootstrap::create(BP, $_SERVER)->getObjectManager();
$changes = $objectManager->get(ChangeDetector::class);
$importers = $objectManager->get(ImporterFactory::class);
$config = $objectManager->get(DeploymentConfig::class);

$warnings = [];
foreach ($objectManager->get(ImporterPool::class)->getImporters() as $section => $importerClass) {
    if (!$changes->hasChanges($section)) {
        continue;
    }
    foreach ($importers->create($importerClass)->getWarningMessages((array) $config->getConfigData($section)) as $message) {
        $warnings[] = ['section' => $section, 'message' => trim(strip_tags((string) $message))];
    }
}
$destructive = array_values(array_filter(
    $warnings,
    static fn (array $w): bool => (bool) preg_match('/will be (deleted|removed)/i', $w['message'])
));

echo json_encode(['warnings' => $warnings, 'destructive' => $destructive], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES), "\n";
