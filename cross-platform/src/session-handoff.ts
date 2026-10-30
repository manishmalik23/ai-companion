import { Request, validId, validRequest } from './protocol';

export interface SessionHandoffActions {
  pending(): Promise<readonly Request[]>;
  destination(request: Request): Promise<string | undefined>;
  navigate(target: string): Promise<void>;
  defer(id: string, snapshot: string): Promise<void>;
  dismiss(id: string, snapshot: string): Promise<void>;
}
/** Retire only the displayed request, after its exact source route opens successfully. */
export class SessionHandoff {
  private readonly opening = new Set<string>();
  constructor(private readonly actions: SessionHandoffActions) {}
  async open(id: unknown, snapshot: unknown): Promise<void> {
    if (!validId(id) || typeof snapshot !== 'string' || snapshot.length === 0 || snapshot.length > 1_000_000) throw new Error('Invalid session request.');
    if (this.opening.has(id)) throw new Error('This session is already opening.');
    this.opening.add(id);
    try {
      const current = async () => {
        const request = (await this.actions.pending()).find(request => request.id === id);
        if (!request) throw new Error('This request has already finished.');
        if (!validRequest(request) || JSON.stringify(request) !== snapshot) throw new Error('This request changed. Review it in Pip before continuing.');
        return request;
      };
      const request = await current(), target = await this.actions.destination(request);
      if (!target) throw new Error('An exact link to this session is unavailable. Return to its original editor or terminal.');
      await current();
      await this.actions.navigate(target);
      await current();
      if (request.kind === 'notice') await this.actions.dismiss(id,snapshot);
      else {
        if (request.kind === 'permission' && request.canDefer !== true) throw new Error('The chat opened. Answer this request in Pip.');
        await this.actions.defer(id,snapshot);
      }
    } finally { this.opening.delete(id); }
  }
}
