<?php

declare(strict_types=1);

namespace Lab\ZdtProbe\Controller\Read;

use Magento\Framework\App\Action\HttpGetActionInterface;
use Magento\Framework\App\ResourceConnection;
use Magento\Framework\Controller\Result\RawFactory;
use Magento\Framework\Controller\ResultInterface;
use Throwable;

/**
 * Reads probe_value_v2 from lab_zdt_probe and answers plain text: 200 with
 * the value, or 500 with the database exception's own message. Production
 * mode would otherwise hide a schema error behind a report number, and the
 * lab fleet's falsifier 3 needs the failure to name the column itself.
 */
class Index implements HttpGetActionInterface
{
    public function __construct(
        private readonly ResourceConnection $resourceConnection,
        private readonly RawFactory $rawFactory
    ) {
    }

    public function execute(): ResultInterface
    {
        $result = $this->rawFactory->create();
        try {
            $connection = $this->resourceConnection->getConnection();
            $value = $connection->fetchOne(
                $connection->select()
                    ->from($this->resourceConnection->getTableName('lab_zdt_probe'), ['probe_value_v2'])
                    ->limit(1)
            );
            $result->setHttpResponseCode(200)->setContents((string) $value);
        } catch (Throwable $e) {
            $result->setHttpResponseCode(500)->setContents($e->getMessage());
        }

        return $result;
    }
}
