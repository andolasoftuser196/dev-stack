<?php
declare(strict_types=1);

namespace App\Controller;

use Cake\Cache\Cache;
use Cake\Controller\Controller;
use Cake\Datasource\ConnectionManager;
use Cake\Http\Response;

class StatusController extends Controller
{
    public function index(): Response
    {
        $lines = [
            'ssmd demo app',
            sprintf('runtime=%s framework=cakephp version=%s',
                    ssmd_env('SSMD_RUNTIME', 'frankenphp'), PHP_VERSION),
            'instance=' . ssmd_env('SSMD_INSTANCE', 'main'),
        ];

        try {
            $c = ConnectionManager::get('default');
            $c->getDriver()->connect();
            $lines[] = 'database=' . $c->config()['database'] . ' ok';
        } catch (\Throwable $e) {
            $lines[] = 'database=FAILED: ' . $e->getMessage();
        }

        try {
            Cache::write('ssmd:demo', 'ok');
            $lines[] = sprintf('cache=db%s %s', ssmd_env('REDIS_DB', '0'),
                               Cache::read('ssmd:demo') === 'ok' ? 'ok' : 'FAILED');
        } catch (\Throwable $e) {
            $lines[] = 'cache=FAILED: ' . $e->getMessage();
        }

        $m = @fsockopen(ssmd_env('MAIL_HOST', 'mailpit'), (int)ssmd_env('MAIL_PORT', '1025'), $n, $s, 5);
        $lines[] = 'mail=' . ($m ? 'ok' : 'FAILED');
        $m && fclose($m);

        $lines[] = 'storage=' . (ssmd_env('S3_ENDPOINT') ? 'ok' : 'skipped');

        return $this->response->withType('text/plain')
            ->withStringBody(implode("\n", $lines) . "\n");
    }
}
