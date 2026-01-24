# Next.js OpenNext Plugin

Deploy Next.js applications to AWS Lambda using OpenNext and CDK.

## Features

- **OpenNext**: Transforms Next.js build for AWS Lambda
- **CDK Integration**: Infrastructure as Code with TypeScript
- **Full Next.js Support**: App Router, Server Components, ISR, Streaming
- **Production Patterns**: Caching, middleware, environment variables

## Skills

### `/nextjs-deploy`

Complete deployment workflow covering:

- OpenNext configuration (`open-next.config.ts`)
- CDK infrastructure with `cdk-nextjs-standalone`
- Manual CDK setup for full control
- App Router file conventions
- Server and Client Components
- Server Actions and data mutations
- ISR with time-based and on-demand revalidation
- CloudFront cache invalidation
- Streaming with Suspense
- Environment variables and secrets
- Common issues and troubleshooting

## Quick Start

```bash
# Install OpenNext
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

- Next.js 14+ with App Router
- Node.js 18+
- AWS CDK v2
- AWS account with appropriate permissions
