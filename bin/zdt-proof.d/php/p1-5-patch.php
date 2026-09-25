<?php

declare(strict_types=1);

use Magento\Framework\Setup\Patch\PatchHistory;

require __DIR__ . '/bootstrap.php';

$patch = 'Kingletas\ZdtProof\Setup\Patch\Data\ZdtMarkerPatch';
$history = zdtObjectManager()->get(PatchHistory::class);

switch ($argv[1] ?? '') {
    case 'mark':
        $history->fixPatch($patch);
        zdtOut('marked=' . $patch);
        break;
    case 'unmark':
        $history->revertPatchFromHistory($patch);
        zdtOut('unmarked=' . $patch);
        break;
    default:
        fwrite(STDERR, "usage: p1-5-patch.php mark|unmark\n");
        exit(2);
}
