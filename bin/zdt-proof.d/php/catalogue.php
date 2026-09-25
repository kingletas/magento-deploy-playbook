<?php

declare(strict_types=1);

use Magento\Catalog\Api\Data\ProductInterfaceFactory;
use Magento\Catalog\Api\ProductRepositoryInterface;
use Magento\Framework\App\State;
use Magento\Framework\Exception\NoSuchEntityException;

require __DIR__ . '/bootstrap.php';

$objectManager = zdtObjectManager();
$objectManager->get(State::class)->setAreaCode('adminhtml');
$repository = $objectManager->get(ProductRepositoryInterface::class);

try {
    $repository->get('zdt-simple');
    zdtOut('product=exists');
    exit(0);
} catch (NoSuchEntityException) {
    zdtOut('product=creating');
}

$product = $objectManager->get(ProductInterfaceFactory::class)->create();
$product->setSku('zdt-simple')
    ->setName('ZDT Simple')
    ->setUrlKey('zdt-simple')
    ->setAttributeSetId(4)
    ->setTypeId('simple')
    ->setPrice(10)
    ->setWeight(1)
    ->setVisibility(4)
    ->setStatus(1)
    ->setWebsiteIds([1])
    ->setStockData(['qty' => 100, 'is_in_stock' => 1, 'use_config_manage_stock' => 1]);
try {
    $repository->save($product);
} catch (Throwable $e) {
    fwrite(STDERR, 'product save failed: ' . get_class($e) . ': ' . $e->getMessage() . PHP_EOL);
    exit(1);
}
zdtOut('product=created');
