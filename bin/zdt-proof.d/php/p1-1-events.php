<?php

declare(strict_types=1);

use Magento\Framework\App\Cache\Frontend\Pool;
use Magento\Framework\Event\ConfigInterface;

require __DIR__ . '/bootstrap.php';

$objectManager = zdtObjectManager();
$frontend = $objectManager->get(Pool::class)->get('default');
zdtOut('release=' . basename(BP));
zdtOut('id_prefix=' . $frontend->getLowLevelFrontend()->getOption('cache_id_prefix'));
zdtOut('observers=' . count($objectManager->get(ConfigInterface::class)->getObservers('zdt_cache_probe')));
