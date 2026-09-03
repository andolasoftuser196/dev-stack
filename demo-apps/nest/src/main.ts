import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  // 0.0.0.0 is required: bound to localhost inside a container the process is
  // unreachable from Caddy, and the symptom is a 502 with an empty app log.
  const port = Number(process.env.PORT ?? process.env.DX_APP_PORT ?? 3000);
  await app.listen(port, '0.0.0.0');
}
bootstrap();
