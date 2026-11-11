import { NextResponse } from 'next/server';
import site from '@/site.json';

// Evaluated on every request so the timestamp is current.
export const dynamic = 'force-dynamic';

export async function GET() {
  return NextResponse.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    service: site.name,
    environment: site.environment,
  });
}
