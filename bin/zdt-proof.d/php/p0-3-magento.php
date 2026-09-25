<?php

declare(strict_types=1);

use Magento\Framework\App\ResourceConnection;
use Magento\Framework\Setup\Declaration\Schema\Operations\ModifyColumn;
use Magento\Framework\Setup\Declaration\Schema\OperationsExecutor;

require __DIR__ . '/bootstrap.php';

$objectManager = zdtObjectManager();

switch ($argv[1] ?? '') {
    case 'destructive':
        zdtOut('destructive_operations=' . implode(',', $objectManager->get(OperationsExecutor::class)->getDestructiveOperations()));
        zdtOut('modify_column_destructive=' . var_export($objectManager->get(ModifyColumn::class)->isOperationDestructive(), true));
        break;

    case 'write-long':
        $connection = $objectManager->get(ResourceConnection::class)->getConnection();
        zdtOut('session_sql_mode=' . $connection->fetchOne('SELECT @@SESSION.sql_mode'));
        $connection->insert('zdt_proof_item', ['sku' => 'written-after', 'qty' => 1, 'note' => 'written by magento after narrowing']);
        foreach ($connection->fetchAll('SHOW WARNINGS') as $warning) {
            zdtOut('warning=' . $warning['Code'] . ' ' . $warning['Message']);
        }
        zdtOut('stored=' . $connection->fetchOne("SELECT note FROM zdt_proof_item WHERE sku = 'written-after'"));
        break;

    default:
        fwrite(STDERR, "usage: p0-3-magento.php destructive|write-long\n");
        exit(2);
}
