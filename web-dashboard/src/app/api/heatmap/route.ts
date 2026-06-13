export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const city = searchParams.get('city') ?? '';
  const hour = searchParams.get('hour') ?? '';
  const backendUrl = process.env.BACKEND_URL ?? 'http://localhost:8000';
  const params = new URLSearchParams();
  if (city) params.set('city', city);
  if (hour) params.set('hour', hour);
  const query = params.toString();
  const res = await fetch(`${backendUrl}/heatmap${query ? `?${query}` : ''}`);
  const data = await res.json();
  return Response.json(data);
}
