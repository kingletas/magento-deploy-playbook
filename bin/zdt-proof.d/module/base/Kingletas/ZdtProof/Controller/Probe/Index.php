<?php

declare(strict_types=1);

namespace Kingletas\ZdtProof\Controller\Probe;

use Kingletas\ZdtProof\Model\ProbeColumns;
use Magento\Framework\App\Action\HttpGetActionInterface;
use Magento\Framework\App\ResourceConnection;
use Magento\Framework\Controller\Result\JsonFactory;
use Magento\Framework\Controller\ResultInterface;

/** Selects the probe columns from the fixture table and returns them. */
class Index implements HttpGetActionInterface
{
    public function __construct(
        private readonly ResourceConnection $resourceConnection,
        private readonly JsonFactory $jsonFactory
    ) {
    }

    public function execute(): ResultInterface
    {
        $connection = $this->resourceConnection->getConnection();
        $select = $connection->select()
            ->from($this->resourceConnection->getTableName('zdt_proof_item'), ProbeColumns::COLUMNS)
            ->limit(5);

        return $this->jsonFactory->create()->setData(['rows' => $connection->fetchAll($select)]);
    }
}
