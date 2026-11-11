/** @type {import('next').NextConfig} */
const nextConfig = {
  // A container image only needs the self-contained server in
  // .next/standalone; `next start` needs the regular output.
  output: process.env.NEXT_OUTPUT === 'standalone' ? 'standalone' : undefined,
  reactStrictMode: true,
  poweredByHeader: false,
};

module.exports = nextConfig;
