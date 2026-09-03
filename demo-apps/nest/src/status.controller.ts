import { Controller, Get, Header } from '@nestjs/common';
import { StatusService } from './status.service';

@Controller()
export class StatusController {
  constructor(private readonly status: StatusService) {}

  // No /healthz route. Caddy answers that in front of this process, and it must
  // keep answering while Nest is restarting after a change.
  @Get()
  @Header('Content-Type', 'text/plain')
  index(): Promise<string> {
    return this.status.render();
  }
}
