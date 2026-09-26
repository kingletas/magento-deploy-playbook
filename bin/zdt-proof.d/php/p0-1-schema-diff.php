<?php

declare(strict_types=1);

use Magento\Framework\Config\FileResolverByModule;
use Magento\Framework\DB\Adapter\SqlVersionProvider;
use Magento\Framework\ObjectManagerInterface;
use Magento\Framework\Setup\Declaration\Schema\Declaration\ReaderComposite;
use Magento\Framework\Setup\Declaration\Schema\Declaration\SchemaBuilder;
use Magento\Framework\Setup\Declaration\Schema\Diff\DiffInterface;
use Magento\Framework\Setup\Declaration\Schema\Diff\SchemaDiff;
use Magento\Framework\Setup\Declaration\Schema\DryRunLogger;
use Magento\Framework\Setup\Declaration\Schema\Dto\Schema;
use Magento\Framework\Setup\Declaration\Schema\Dto\SchemaFactory;
use Magento\Framework\Setup\Declaration\Schema\Dto\TableElementInterface;
use Magento\Framework\Setup\Declaration\Schema\OperationsExecutor;

require __DIR__ . '/bootstrap.php';

/** Answers the server version from ZDT_SQL_VERSION, so a schema can be built with no server. */
class ZdtFixedSqlVersionProvider extends SqlVersionProvider
{
    public function getSqlVersion(string $resource = 'default'): string
    {
        return (string) getenv('ZDT_SQL_VERSION');
    }

    public function isMysqlGte8029(): bool
    {
        return false;
    }

    public function isMariaDbEngine(): bool
    {
        return true;
    }

    public function getMariaDbSuffixKey(): string
    {
        return SqlVersionProvider::MARIA_DB_10_6_11_VERSION;
    }
}

function readTables(ObjectManagerInterface $objectManager): array
{
    return $objectManager->create(ReaderComposite::class)->read(FileResolverByModule::ALL_MODULES)['table'];
}

function buildSchema(ObjectManagerInterface $objectManager, array $tables): Schema
{
    $builder = $objectManager->create(SchemaBuilder::class);

    return $builder->addTablesData($tables)->build($objectManager->get(SchemaFactory::class)->create());
}

/** One line per registered change, as "operation table.element". */
function describeDiff(DiffInterface $diff): array
{
    $lines = [];
    foreach ($diff->getAll() ?? [] as $operations) {
        foreach ($operations as $operation => $histories) {
            foreach ($histories as $history) {
                $element = $history->getNew() ?? $history->getOld();
                $name = $element instanceof TableElementInterface
                    ? $element->getTable()->getName() . '.' . $element->getName()
                    : $element->getName();
                $lines[] = $operation . ' ' . $name;
            }
        }
    }

    return $lines;
}

function renderSql(ObjectManagerInterface $objectManager, DiffInterface $diff, string $target): void
{
    $log = BP . '/var/log/' . DryRunLogger::FILE_NAME;
    if (file_exists($log)) {
        unlink($log);
    }
    $objectManager->get(OperationsExecutor::class)->execute($diff, [DryRunLogger::INPUT_KEY_DRY_RUN_MODE => true]);
    copy(file_exists($log) ? $log : '/dev/null', $target);
}

$command = $argv[1] ?? '';
$out = $argv[2] ?? '';
$objectManager = zdtObjectManager();
if (getenv('ZDT_SQL_VERSION')) {
    $objectManager->configure(['preferences' => [SqlVersionProvider::class => ZdtFixedSqlVersionProvider::class]]);
}
$schemaDiff = $objectManager->get(SchemaDiff::class);

try {
    switch ($command) {
        case 'probe':
            $schema = buildSchema($objectManager, readTables($objectManager));
            zdtOut('tables=' . count($schema->getTables()));
            zdtOut('connections=' . implode(',', zdtOpenedConnections($objectManager)));
            break;

        case 'self-diff':
            $tables = readTables($objectManager);
            $changes = describeDiff($schemaDiff->diff(buildSchema($objectManager, $tables), buildSchema($objectManager, $tables)));
            zdtOut('self_changes=' . count($changes));
            $altered = $tables;
            $altered['cms_block']['column']['title']['length'] = '100';
            $changes = describeDiff($schemaDiff->diff(buildSchema($objectManager, $altered), buildSchema($objectManager, $tables)));
            zdtOut('control_changes=' . count($changes));
            array_map(static fn ($line) => zdtOut('control ' . $line), $changes);
            zdtOut('connections=' . implode(',', zdtOpenedConnections($objectManager)));
            break;

        case 'dump':
            $tables = readTables($objectManager);
            file_put_contents("$out/tables.json", json_encode($tables, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
            zdtOut('json_bytes=' . filesize("$out/tables.json"));
            $schema = buildSchema($objectManager, $tables);
            try {
                file_put_contents("$out/schema.ser", serialize($schema));
                zdtOut('serialize_bytes=' . filesize("$out/schema.ser"));
            } catch (Throwable $e) {
                zdtOut('serialize_error=' . get_class($e) . ': ' . $e->getMessage());
            }
            zdtOut('connections=' . implode(',', zdtOpenedConnections($objectManager)));
            break;

        case 'roundtrip':
            $fresh = buildSchema($objectManager, readTables($objectManager));
            $fromJson = buildSchema($objectManager, json_decode(file_get_contents("$out/tables.json"), true, 512, JSON_THROW_ON_ERROR));
            zdtOut('json_roundtrip_changes=' . count(describeDiff($schemaDiff->diff($fresh, $fromJson))));
            if (file_exists("$out/schema.ser")) {
                try {
                    $fromSer = unserialize(file_get_contents("$out/schema.ser"));
                    zdtOut('serialize_roundtrip_changes=' . count(describeDiff($schemaDiff->diff($fresh, $fromSer))));
                } catch (Throwable $e) {
                    zdtOut('serialize_roundtrip_error=' . get_class($e) . ': ' . $e->getMessage());
                }
            }
            break;

        case 'diff':
            $old = buildSchema($objectManager, json_decode(file_get_contents("$out/tables.json"), true, 512, JSON_THROW_ON_ERROR));
            $new = buildSchema($objectManager, readTables($objectManager));
            $diff = $schemaDiff->diff($new, $old);
            $changes = describeDiff($diff);
            zdtOut('changes=' . count($changes));
            array_map(static fn ($line) => zdtOut('change ' . $line), $changes);
            zdtOut('connections_before_sql=' . implode(',', zdtOpenedConnections($objectManager)));
            renderSql($objectManager, $diff, "$out/two-revision.sql");
            zdtOut('connections_after_sql=' . implode(',', zdtOpenedConnections($objectManager)));
            break;

        default:
            fwrite(STDERR, "usage: p0-1-schema-diff.php probe|self-diff|dump|roundtrip|diff [outdir]\n");
            exit(2);
    }
} catch (Throwable $e) {
    zdtOut('error=' . get_class($e) . ': ' . $e->getMessage());
    zdtOut('connections=' . implode(',', zdtOpenedConnections($objectManager)));
    exit(1);
}
