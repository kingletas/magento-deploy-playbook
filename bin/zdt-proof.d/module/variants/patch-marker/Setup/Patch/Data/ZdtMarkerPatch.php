<?php

declare(strict_types=1);

namespace Kingletas\ZdtProof\Setup\Patch\Data;

use Magento\Framework\Setup\ModuleDataSetupInterface;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/** Inserts one marker row, so whether this patch ran is observed rather than inferred. */
class ZdtMarkerPatch implements DataPatchInterface
{
    public function __construct(private readonly ModuleDataSetupInterface $moduleDataSetup)
    {
    }

    public function apply(): self
    {
        $this->moduleDataSetup->getConnection()->insert(
            $this->moduleDataSetup->getTable('zdt_proof_item'),
            ['sku' => 'patch-applied', 'qty' => 1]
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
