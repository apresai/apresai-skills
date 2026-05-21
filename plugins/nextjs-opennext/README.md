# Next.js OpenNext Plugin

Deploy Next.js applications to AWS Lambda using OpenNext and CDK.

## Features

- **OpenNext v4**: Transforms Next.js 16 build for AWS Lambda via the stable Adapter API
- **CDK Integration**: Infrastructure as Code with TypeScript
- **Full Next.js 16 Support**: App Router, Cache Components, `use cache` directive, PPR, Streaming, ISR
- **Production Patterns**: Caching, middleware, environment variables, streaming workarounds

## Skills

### `/nextjs-deploy`

Complete deployment workflow covering:

- Construct selection guide (`cdk-nextjs-standalone` vs `cdklabs/cdk-nextjs` vs manual CDK)
- OpenNext v3 vs v4 differences
- Next.js 16 features (Cache Components, `use cache`, PPR, Turbopack, React Compiler)
- OpenNext configuration (`open-next.config.ts`)
- CDK infrastructure with `cdk-nextjs-standalone`
- Manual CDK setup for full control (`NODEJS_22_X`, ARM64, `S3BucketOrigin.withOriginAccessControl`)
- App Router file conventions
- Server and Client Components
- Server Actions and data mutations
- ISR with time-based and on-demand revalidation
- CloudFront cache invalidation
- Streaming with Suspense + `OPEN_NEXT_FORCE_NON_EMPTY_RESPONSE` workaround
- Environment variables and secrets
- Alternatives (Vercel, SST, Amplify)
- Common issues and troubleshooting

## Quick Start

```bash
# Install OpenNext (installs latest v4.x)
npm install @opennextjs/aws

# Create config
cat > open-next.config.ts << 'EOF'
import type { OpenNextConfig } from "@opennextjs/aws/types/open-next.js";
const config: OpenNextConfig = { default: {} };
export default config;
EOF

# Build and deploy
npx open-next build
cd infrastructure && npx cdk deploy
```

## Requirements

- Next.js 15.x (OpenNext v3.10) or Next.js 16.x (OpenNext v4 + Adapter API)
- Node.js 22+ — Lambda runtime `NODEJS_22_X` (`NODEJS_20_X` reached Lambda EOL 2026-04-30)
- AWS CDK v2
- AWS account with appropriate permissions
