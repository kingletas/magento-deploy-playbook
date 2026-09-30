<?php

declare(strict_types=1);

namespace Lab\ZdtProbe\Setup\Patch\Data;

use Magento\Framework\Setup\ModuleDataSetupInterface;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/** Inserts one probe row, so /zdtprobe/read always has a value to read. */
class InsertProbeRow implements DataPatchInterface
{
    public function __construct(private readonly ModuleDataSetupInterface $moduleDataSetup)
    {
    }

    public function apply(): self
    {
        $this->moduleDataSetup->getConnection()->insert(
            $this->moduleDataSetup->getTable('lab_zdt_probe'),
            ['probe_value' => 'zdt-probe']
        );

        return $this;
    }

    public static function getDependencies(): array
    {
        return [];
    }

    public function getAliases(): array
    {
        return [];
    }
}
