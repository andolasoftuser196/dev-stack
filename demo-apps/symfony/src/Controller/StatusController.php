<?php

namespace App\Controller;

use Doctrine\DBAL\DriverManager;
use Doctrine\DBAL\Tools\DsnParser;
use Symfony\Component\HttpFoundation\Response;

class StatusController
{
    public function index(): Response
    {
        $lines = [
            'dx demo app',
            sprintf('runtime=%s framework=symfony version=%s',
                    $_ENV['DX_RUNTIME'] ?? 'frankenphp', PHP_VERSION),
            'instance=' . ($_ENV['DX_INSTANCE'] ?? 'main'),
        ];

        // Built from DATABASE_URL, which is what dx injects and what
        // config/packages/doctrine.yaml reads — so this probe and the migration
        // that just ran are demonstrably talking to the same database.
        $name = $_ENV['DB_DATABASE'] ?? '';
        try {
            $conn = DriverManager::getConnection(
                (new DsnParser(['mysql' => 'pdo_mysql', 'postgresql' => 'pdo_pgsql']))
                    ->parse($_ENV['DATABASE_URL'] ?? '')
            );
            $conn->executeQuery('SELECT 1');
            $lines[] = "database=$name ok";
        } catch (\Throwable $e) {
            $lines[] = "database=$name FAILED: " . $e->getMessage();
        }

        try {
            $r = new \Redis();
            $r->connect($_ENV['REDIS_HOST'] ?? 'redis', (int) ($_ENV['REDIS_PORT'] ?? 6379), 5.0);
            $db = (int) ($_ENV['REDIS_DB'] ?? 0);
            $r->select($db);
            $r->setex('dx:demo', 30, 'ok');
            $lines[] = sprintf('cache=db%d %s', $db, $r->get('dx:demo') === 'ok' ? 'ok' : 'FAILED');
        } catch (\Throwable $e) {
            $lines[] = 'cache=FAILED: ' . $e->getMessage();
        }

        $m = @fsockopen($_ENV['MAIL_HOST'] ?? 'mailpit', (int) ($_ENV['MAIL_PORT'] ?? 1025), $n, $s, 5);
        $lines[] = 'mail=' . ($m ? 'ok' : 'FAILED');
        $m && fclose($m);

        $lines[] = 'storage=' . (($_ENV['S3_ENDPOINT'] ?? '') !== '' ? 'ok' : 'skipped');

        return new Response(implode("\n", $lines) . "\n", 200, ['Content-Type' => 'text/plain']);
    }
}
