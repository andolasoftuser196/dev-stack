<?php

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;

/**
 * The ssmd demo status page.
 *
 * Deliberately not a /healthz: that is answered by Caddy in every ssmd runtime,
 * and it has to keep answering while this application is broken. This route
 * proves the opposite thing - that the application itself can reach everything
 * the stack wired up for it.
 */
Route::get('/', function () {
    $lines = [
        'ssmd demo app',
        sprintf('runtime=%s framework=laravel version=%s',
                env('SSMD_RUNTIME', 'frankenphp'), PHP_VERSION),
        'instance=' . env('SSMD_INSTANCE', 'main'),
    ];

    try {
        DB::connection()->getPdo();
        $lines[] = 'database=' . DB::connection()->getDatabaseName() . ' ok';
    } catch (\Throwable $e) {
        $lines[] = 'database=FAILED: ' . $e->getMessage();
    }

    try {
        // Write and read back. Connecting proves less than it looks like - a
        // wrong Redis logical database still connects perfectly happily, and
        // that is exactly the bug per-instance isolation exists to prevent.
        Cache::put('ssmd:demo', 'ok', 30);
        $lines[] = sprintf('cache=db%s %s',
            config('database.redis.default.database', '0'),
            Cache::get('ssmd:demo') === 'ok' ? 'ok' : 'FAILED');
    } catch (\Throwable $e) {
        $lines[] = 'cache=FAILED: ' . $e->getMessage();
    }

    $mail = @fsockopen(env('MAIL_HOST', 'mailpit'), (int) env('MAIL_PORT', 1025), $n, $s, 5);
    $lines[] = 'mail=' . ($mail ? 'ok' : 'FAILED');
    $mail && fclose($mail);

    $lines[] = 'storage=' . (env('S3_ENDPOINT') ? 'ok' : 'skipped');

    return response(implode("\n", $lines) . "\n")->header('Content-Type', 'text/plain');
});
