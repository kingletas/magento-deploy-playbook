<?php

declare(strict_types=1);

namespace Lab\ZdtProbe\Setup\Patch\Data;

use Magento\Framework\Setup\ModuleDataSetupInterface;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/** Inserts one probe row under the renamed column, so /zdtprobe/read has a value to read on new code. */
class InsertProbeRow implements DataPatchInterface
{
    public function __construct(private readonly ModuleDataSetupInterface $moduleDataSetup)
    {
    }

    public function apply(): self
    {
        $this->moduleDataSetup->getConnection()->insert(
            $this->moduleDataSetup->getTable('lab_zdt_probe'),
            ['probe_value_v2' => 'zdt-probe']
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
