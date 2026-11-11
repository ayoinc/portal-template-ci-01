import site from '@/site.json';

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center p-24">
      <h1 className="text-4xl font-bold mb-4">{site.name}</h1>
      <p className="text-lg text-gray-600">{site.description}</p>
      <div className="mt-8 flex gap-4">
        <a
          href="/api/health"
          className="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600"
        >
          Health Check
        </a>
      </div>
    </main>
  );
}
