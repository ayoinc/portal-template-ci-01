/**
 * @jest-environment node
 */
import { GET } from '@/app/api/health/route';
import site from '@/site.json';

describe('GET /api/health', () => {
  it('reports the service as healthy', async () => {
    const response = await GET();
    expect(response.status).toBe(200);

    const body = await response.json();
    expect(body.status).toBe('healthy');
    expect(body.service).toBe(site.name);
    expect(body.environment).toBe(site.environment);
    expect(Number.isNaN(Date.parse(body.timestamp))).toBe(false);
  });
});
