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
            'dx demo app',
            sprintf('runtime=%s framework=cakephp version=%s',
                    dx_env('DX_RUNTIME', 'frankenphp'), PHP_VERSION),
            'instance=' . dx_env('DX_INSTANCE', 'main'),
        ];

        try {
            $c = ConnectionManager::get('default');
            $c->getDriver()->connect();
            $lines[] = 'database=' . $c->config()['database'] . ' ok';
        } catch (\Throwable $e) {
            $lines[] = 'database=FAILED: ' . $e->getMessage();
        }

        try {
            Cache::write('dx:demo', 'ok');
            $lines[] = sprintf('cache=db%s %s', dx_env('REDIS_DB', '0'),
                               Cache::read('dx:demo') === 'ok' ? 'ok' : 'FAILED');
        } catch (\Throwable $e) {
            $lines[] = 'cache=FAILED: ' . $e->getMessage();
        }

        $m = @fsockopen(dx_env('MAIL_HOST', 'mailpit'), (int)dx_env('MAIL_PORT', '1025'), $n, $s, 5);
        $lines[] = 'mail=' . ($m ? 'ok' : 'FAILED');
        $m && fclose($m);

        $lines[] = 'storage=' . (dx_env('S3_ENDPOINT') ? 'ok' : 'skipped');

        return $this->response->withType('text/plain')
            ->withStringBody(implode("\n", $lines) . "\n");
    }
}
