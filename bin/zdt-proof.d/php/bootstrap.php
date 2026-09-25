<?php

declare(strict_types=1);

use Magento\Framework\App\Bootstrap;
use Magento\Framework\App\Filesystem\DirectoryList;
use Magento\Framework\App\ResourceConnection;
use Magento\Framework\ObjectManagerInterface;

require getcwd() . '/app/bootstrap.php';

/** Build an object manager for the store in the working directory, optionally reading app/etc from elsewhere. */
function zdtObjectManager(): ObjectManagerInterface
{
    $params = $_SERVER;
    $configDir = getenv('ZDT_CONFIG_DIR');
    if ($configDir) {
        $params[Bootstrap::INIT_PARAM_FILESYSTEM_DIR_PATHS] = [
            DirectoryList::CONFIG => [DirectoryList::PATH => $configDir],
        ];
    }

    return Bootstrap::create(BP, $params)->getObjectManager();
}

/** Connections a ResourceConnection has actually opened; an adapter it only created, without connecting, is not one. */
function zdtOpenedConnections(ObjectManagerInterface $objectManager): array
{
    $resource = $objectManager->get(ResourceConnection::class);
    $property = new ReflectionProperty(ResourceConnection::class, 'connections');
    $opened = array_filter($property->getValue($resource), static fn ($adapter) => $adapter->isConnected());

    return array_keys($opened);
}

function zdtOut(string $line): void
{
    fwrite(STDOUT, $line . PHP_EOL);
}
