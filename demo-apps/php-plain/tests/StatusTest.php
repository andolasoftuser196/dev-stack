<?php
declare(strict_types=1);

use Ssmd\Demo\Status;
use PHPUnit\Framework\TestCase;

final class StatusTest extends TestCase
{
    public function testRendersTheAgreedShape(): void
    {
        $out = Status::all('none');
        $this->assertStringStartsWith('ssmd demo app', $out);
        $this->assertStringContainsString('runtime=', $out);
        $this->assertStringContainsString('instance=', $out);
    }

    /**
     * ssmd points the suite at <db>_test and refuses to run if that name does not
     * look disposable. Asserting it here means the guard is visible from inside
     * the project too, not only in the toolkit.
     */
    public function testRunsAgainstADisposableDatabase(): void
    {
        $db = getenv('DB_DATABASE');
        if ($db === false || $db === '') {
            $this->markTestSkipped('no database configured');
        }
        $this->assertMatchesRegularExpression('/(_test|_sandbox)$/', $db,
            'the suite must never point at the development database');
    }
}
