<?php

declare(strict_types=1);

namespace Kingletas\ZdtProof\Model;

/** The columns the probe selects, which is what a release changes to put code ahead of the schema. */
class ProbeColumns
{
    public const COLUMNS = ['item_id', 'sku', 'qty', 'colour'];
}
