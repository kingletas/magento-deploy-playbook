<?php

declare(strict_types=1);

namespace Kingletas\ZdtProof\Model;

use Magento\Framework\App\Filesystem\DirectoryList;
use Magento\Framework\Setup\Declaration\Schema\Db\DbSchemaWriterInterface;
use Magento\Framework\Setup\Declaration\Schema\Db\MySQL\DbSchemaWriter;
use Magento\Framework\Setup\Declaration\Schema\Db\StatementAggregator;
use Magento\Framework\Setup\Declaration\Schema\DryRunLogger;

/** Records every statement it is asked to compile, then hands everything to the stock writer. */
class RecordingSchemaWriter implements DbSchemaWriterInterface
{
    public function __construct(
        private readonly DbSchemaWriter $stock,
        private readonly DirectoryList $directoryList,
        private readonly DryRunLogger $dryRunLogger
    ) {
    }

    /** @inheritDoc */
    public function createTable($tableName, $resource, array $definition, array $options)
    {
        return $this->stock->createTable($tableName, $resource, $definition, $options);
    }

    /** @inheritDoc */
    public function dropTable($tableName, $resource)
    {
        return $this->stock->dropTable($tableName, $resource);
    }

    /** @inheritDoc */
    public function addElement($elementName, $resource, $tableName, $elementDefinition, $elementType)
    {
        return $this->stock->addElement($elementName, $resource, $tableName, $elementDefinition, $elementType);
    }

    /** @inheritDoc */
    public function resetAutoIncrement($tableName, $resource)
    {
        return $this->stock->resetAutoIncrement($tableName, $resource);
    }

    /** @inheritDoc */
    public function modifyColumn($columnName, $resource, $tableName, $columnDefinition)
    {
        return $this->stock->modifyColumn($columnName, $resource, $tableName, $columnDefinition);
    }

    /** @inheritDoc */
    public function modifyTableOption($tableName, $resource, $optionName, $optionValue)
    {
        return $this->stock->modifyTableOption($tableName, $resource, $optionName, $optionValue);
    }

    /** @inheritDoc */
    public function dropElement($resource, $elementName, $tableName, $type)
    {
        return $this->stock->dropElement($resource, $elementName, $tableName, $type);
    }

    /** @inheritDoc */
    public function compile(StatementAggregator $statementAggregator, $dryRun)
    {
        $log = $this->directoryList->getPath(DirectoryList::VAR_DIR) . '/zdt-recorded.sql';
        foreach ($statementAggregator->getStatementsBank() as $bank) {
            foreach ($bank as $statement) {
                file_put_contents(
                    $log,
                    $statement->getType() . ' ' . $statement->getTableName() . ' ' . $statement->getStatement() . PHP_EOL,
                    FILE_APPEND
                );
            }
        }
        $this->stock->compile($statementAggregator, $dryRun);
        if (getenv('ZDT_WRITER_MUTATE') && $dryRun) {
            $this->dryRunLogger->log('-- a statement the stock writer never emitted');
        }
    }
}
