import { Injectable } from '@nestjs/common';
import * as net from 'node:net';

/**
 * The ssmd demo status probe.
 *
 * TCP reachability rather than a driver per service: pulling in pg, ioredis and
 * an SMTP client to answer "is it reachable" would make the demo's dependency
 * list larger than the demo.
 */
@Injectable()
export class StatusService {
  private reachable(host: string, port: number, timeout = 5000): Promise<boolean> {
    return new Promise((resolve) => {
      const s = net.createConnection({ host, port });
      const done = (ok: boolean) => { s.destroy(); resolve(ok); };
      s.setTimeout(timeout);
      s.on('connect', () => done(true));
      s.on('error', () => done(false));
      s.on('timeout', () => done(false));
    });
  }

  async render(): Promise<string> {
    const env = process.env;
    const lines = [
      'ssmd demo app',
      `runtime=${env.SSMD_RUNTIME ?? 'node'} framework=nest version=${process.versions.node}`,
      `instance=${env.SSMD_INSTANCE ?? 'main'}`,
    ];

    lines.push(env.DB_DATABASE
      ? `database=${env.DB_DATABASE} ${(await this.reachable(env.DB_HOST!, Number(env.DB_PORT))) ? 'ok' : 'FAILED'}`
      : 'database=skipped');

    lines.push(env.REDIS_HOST
      ? `cache=db${env.REDIS_DB ?? '0'} ${(await this.reachable(env.REDIS_HOST, Number(env.REDIS_PORT ?? 6379))) ? 'ok' : 'FAILED'}`
      : 'cache=skipped');

    lines.push(env.MAIL_HOST
      ? `mail=${(await this.reachable(env.MAIL_HOST, Number(env.MAIL_PORT ?? 1025))) ? 'ok' : 'FAILED'}`
      : 'mail=skipped');

    lines.push(`storage=${env.S3_ENDPOINT ? 'ok' : 'skipped'}`);
    return lines.join('\n') + '\n';
  }
}
