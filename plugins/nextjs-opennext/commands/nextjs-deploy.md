---
name: nextjs-deploy
description: Deploy Next.js applications to AWS Lambda using OpenNext and CDK. Use when deploying Next.js apps with App Router, Server Components, ISR, or streaming to AWS infrastructure.
---

# Next.js OpenNext AWS Deployment - Complete Reference

## Overview

Deploy Next.js applications to AWS using:
- **OpenNext**: Transforms Next.js build output for AWS Lambda
- **CDK**: Infrastructure as Code with TypeScript
- **Node.js 22** Lambda runtime (`NODEJS_22_X`) — required; `NODEJS_20_X` reached Lambda EOL 2026-04-30

## Choosing a Construct (Start Here)

Three live options for deploying Next.js on AWS CDK as of 2026:

| Option | Package | Status | When to use |
|--------|---------|--------|-------------|
| `cdk-nextjs-standalone` (jetbridge) | npm | Stable, v4.x | Most projects today; mature, battle-tested, OpenNext v3/v4 |
| `cdklabs/cdk-nextjs` (AWS Labs) | npm | 0.5 beta | Next.js 16.2+ on the public Adapter API; AWS's strategic direction; not yet stable |
| Manual CDK | aws-cdk-lib | Always available | Full control; function splitting; custom routing logic |

**Pick `cdk-nextjs-standalone`** for new projects today unless you specifically need the public Adapter API topology options from `cdklabs/cdk-nextjs`. The AWS Labs construct is still in beta (0.5.0-beta) as of May 2026 — wait for stable before using in production.

**Future direction**: Next.js 16.2 shipped a stable public Adapter API in March 2026. OpenNext is rebuilding on it; `cdklabs/cdk-nextjs` uses it today. Expect a v5-era OpenNext paired with a stable `cdklabs/cdk-nextjs` to become the recommendation by late 2026.

---

## OpenNext v3 vs v4

`@opennextjs/aws` installs the latest by default — **v4.x as of May 2026**.

- **v3.10.x**: Targets Next.js up to 15.x. SWR tag revalidation, non-200 ISR status codes, query-string preservation through i18n redirects, symlink dereferencing in `public/`. Still works; `cdk-nextjs-standalone` 4.x uses it.
- **v4.0+ (May 2026)**: First version coordinated with the Next.js 16.2 stable Adapter API. Rebuilt internal interface; new monorepo structure with Cloudflare/AWS adapters co-developed. Required for full Next.js 16 support including Cache Components and Dynamic IO.

Pin explicitly if you need v3 behavior on a Next.js 15 project:
```bash
npm install @opennextjs/aws@^3.10
```

For Next.js 16+ projects, use the latest:
```bash
npm install @opennextjs/aws
```

---

## Next.js 16 Features

Next.js 16 (October 2025 GA) introduced several first-class features. OpenNext v4 supports them via the Adapter API path.

### Cache Components (`use cache` directive)

```tsx
// app/dashboard/stats.tsx
"use cache"; // Opt this component into the cache layer

export async function Stats() {
  const data = await fetchExpensiveData();
  return <StatsDisplay data={data} />;
}
```

Enable in `next.config.ts`:
```typescript
// next.config.ts
const nextConfig = {
  cacheComponents: true, // Replaces experimental.ppr from Next.js 14/15
};
export default nextConfig;
```

**Note**: The `experimental.ppr` flag and `experimental_ppr` route segment config are **removed** in Next.js 16. Do not use them.

### Partial Prerendering (PPR) — Now Default

PPR is default behavior under `cacheComponents: true`. No separate flag needed. Routes that mix static and dynamic content automatically benefit from shell-first streaming.

### Turbopack (Stable)

Turbopack is stable in Next.js 16. Use it for development to dramatically reduce rebuild times:
```bash
next dev --turbopack
```

OpenNext consumes the standard `.next` build output — Turbopack affects only the dev experience and build performance, not the Lambda artifact.

### React Compiler (Stable)

```typescript
// next.config.ts
const nextConfig = {
  experimental: {
    reactCompiler: true,
  },
};
```

Automatic memoization; eliminates most manual `useMemo`/`useCallback`. OpenNext passes through React Compiler output unchanged.

---

## Quick Start

### 1. Install Dependencies

```bash
npm install @opennextjs/aws
npm install -D aws-cdk-lib constructs
```

### 2. Create OpenNext Config

```typescript
// open-next.config.ts
import type { OpenNextConfig } from "@opennextjs/aws/types/open-next.js";

const config: OpenNextConfig = {
  default: {},
};

export default config;
```

### 3. Build and Deploy

```bash
npx open-next build
npx cdk deploy
```

---

## OpenNext Configuration

### Minimal Configuration

```typescript
// open-next.config.ts
import type { OpenNextConfig } from "@opennextjs/aws/types/open-next.js";

const config: OpenNextConfig = {
  default: {},
};

export default config;
```

### Full Configuration

```typescript
// open-next.config.ts
import type { OpenNextConfig } from "@opennextjs/aws/types/open-next.js";

const config: OpenNextConfig = {
  // Default server function settings
  default: {
    // Override components
    override: {
      wrapper: "aws-lambda-streaming", // Enable streaming (all regions as of April 2026)
      converter: "aws-apigw-v2",
      // Custom implementations
      tagCache: "dynamodb-lite",
      incrementalCache: "s3-lite",
      queue: "sqs-lite",
    },
  },

  // External middleware (runs on every request including cached)
  middleware: {
    external: true,
    override: {
      wrapper: "aws-lambda",
      converter: "aws-cloudfront",
    },
  },

  // Image optimization settings
  imageOptimization: {
    arch: "arm64",
  },

  // Build options
  buildCommand: "npm run build",
  buildOutputPath: ".open-next",
  appPath: ".", // For monorepos: "packages/web"
  packageJsonPath: ".",

  // Dangerous options (use with caution)
  dangerous: {
    disableIncrementalCache: false,
    disableTagCache: false,
  },
};

export default config;
```

### Function Splitting

Split routes across multiple Lambda functions for optimization:

```typescript
// open-next.config.ts
const config: OpenNextConfig = {
  default: {
    // Handles routes not matched by other functions
  },

  functions: {
    // Heavy API routes get more memory
    api: {
      patterns: ["api/*"],
      override: {
        wrapper: "aws-lambda",
      },
    },

    // Static pages with minimal resources
    marketing: {
      patterns: ["about", "contact", "pricing"],
    },
  },
};
```

---

## CDK Infrastructure

### Using cdk-nextjs-standalone Construct

```typescript
// infrastructure/lib/stack.ts
import * as cdk from "aws-cdk-lib";
import { Nextjs, NextjsDistribution } from "cdk-nextjs-standalone";
import { Construct } from "constructs";

export class NextjsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const nextjs = new Nextjs(this, "Nextjs", {
      nextjsPath: "../", // Path to Next.js app

      // Environment variables
      environment: {
        DATABASE_URL: process.env.DATABASE_URL!,
        NEXT_PUBLIC_API_URL: "https://api.example.com",
      },

      // Build settings
      buildCommand: "npm run build",

      // Lambda settings
      defaults: {
        lambda: {
          memorySize: 1024,
          timeout: cdk.Duration.seconds(30),
          architecture: cdk.aws_lambda.Architecture.ARM_64,
        },
      },
    });

    // Output the CloudFront URL
    new cdk.CfnOutput(this, "CloudFrontUrl", {
      value: `https://${nextjs.distribution.distributionDomainName}`,
    });
  }
}
```

### Custom Domain with Route53

```typescript
import * as route53 from "aws-cdk-lib/aws-route53";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as targets from "aws-cdk-lib/aws-route53-targets";

export class NextjsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const domainName = "example.com";

    // Look up hosted zone
    const hostedZone = route53.HostedZone.fromLookup(this, "Zone", {
      domainName,
    });

    // Create certificate
    const certificate = new acm.Certificate(this, "Certificate", {
      domainName,
      subjectAlternativeNames: [`www.${domainName}`],
      validation: acm.CertificateValidation.fromDns(hostedZone),
    });

    const nextjs = new Nextjs(this, "Nextjs", {
      nextjsPath: "../",
      customDomain: {
        domainName,
        certificate,
        hostedZone,
      },
    });

    // Create A record
    new route53.ARecord(this, "AliasRecord", {
      zone: hostedZone,
      target: route53.RecordTarget.fromAlias(
        new targets.CloudFrontTarget(nextjs.distribution.distribution)
      ),
    });
  }
}
```

### Manual CDK Setup (Full Control)

```typescript
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3deploy from "aws-cdk-lib/aws-s3-deployment";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as origins from "aws-cdk-lib/aws-cloudfront-origins";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as sqs from "aws-cdk-lib/aws-sqs";
import { Construct } from "constructs";
import * as path from "path";

export class NextjsManualStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // S3 bucket for static assets and cache
    const bucket = new s3.Bucket(this, "AssetsBucket", {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // DynamoDB table for cache tags
    const cacheTable = new dynamodb.Table(this, "CacheTable", {
      partitionKey: { name: "path", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "tag", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // Add GSI for tag-based lookups
    cacheTable.addGlobalSecondaryIndex({
      indexName: "tag-index",
      partitionKey: { name: "tag", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "revalidatedAt", type: dynamodb.AttributeType.NUMBER },
    });

    // SQS queue for ISR revalidation
    const revalidationQueue = new sqs.Queue(this, "RevalidationQueue", {
      fifo: true,
      contentBasedDeduplication: true,
      visibilityTimeout: cdk.Duration.seconds(60),
    });

    // Server function — Node 22, ARM64
    const serverFunction = new lambda.Function(this, "ServerFunction", {
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      handler: "index.handler",
      code: lambda.Code.fromAsset(
        path.join(__dirname, "../../.open-next/server-functions/default")
      ),
      memorySize: 1024,
      timeout: cdk.Duration.seconds(30),
      environment: {
        CACHE_BUCKET_NAME: bucket.bucketName,
        CACHE_BUCKET_KEY_PREFIX: "_cache",
        CACHE_BUCKET_REGION: this.region,
        CACHE_DYNAMO_TABLE: cacheTable.tableName,
        REVALIDATION_QUEUE_URL: revalidationQueue.queueUrl,
        REVALIDATION_QUEUE_REGION: this.region,
        // Workaround: prevents Lambda buffering from hanging on empty streaming bodies
        OPEN_NEXT_FORCE_NON_EMPTY_RESPONSE: "true",
      },
    });

    // Grant permissions
    bucket.grantReadWrite(serverFunction);
    cacheTable.grantReadWriteData(serverFunction);
    revalidationQueue.grantSendMessages(serverFunction);

    // Image optimization function — Node 22, ARM64
    const imageFunction = new lambda.Function(this, "ImageFunction", {
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      handler: "index.handler",
      code: lambda.Code.fromAsset(
        path.join(__dirname, "../../.open-next/image-optimization-function")
      ),
      memorySize: 1536,
      timeout: cdk.Duration.seconds(25),
      environment: {
        BUCKET_NAME: bucket.bucketName,
        BUCKET_KEY_PREFIX: "assets",
      },
    });

    bucket.grantRead(imageFunction);

    // Revalidation function — Node 22, ARM64
    const revalidationFunction = new lambda.Function(
      this,
      "RevalidationFunction",
      {
        runtime: lambda.Runtime.NODEJS_22_X,
        architecture: lambda.Architecture.ARM_64,
        handler: "index.handler",
        code: lambda.Code.fromAsset(
          path.join(__dirname, "../../.open-next/revalidation-function")
        ),
        memorySize: 256,
        timeout: cdk.Duration.seconds(30),
      }
    );

    // Add SQS event source to revalidation function
    revalidationFunction.addEventSource(
      new cdk.aws_lambda_event_sources.SqsEventSource(revalidationQueue, {
        batchSize: 5,
      })
    );

    // Deploy static assets to S3
    new s3deploy.BucketDeployment(this, "DeployAssets", {
      sources: [
        s3deploy.Source.asset(
          path.join(__dirname, "../../.open-next/assets")
        ),
      ],
      destinationBucket: bucket,
      destinationKeyPrefix: "assets",
      cacheControl: [
        s3deploy.CacheControl.maxAge(cdk.Duration.days(365)),
        s3deploy.CacheControl.sMaxAge(cdk.Duration.days(365)),
      ],
    });

    // Create Lambda function URLs
    const serverUrl = serverFunction.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
    });

    const imageUrl = imageFunction.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
    });

    // CloudFront distribution
    // Note: origins.S3Origin is deprecated in CDK v2; use S3BucketOrigin.withOriginAccessControl
    const s3Origin = origins.S3BucketOrigin.withOriginAccessControl(bucket);

    const distribution = new cloudfront.Distribution(this, "Distribution", {
      defaultBehavior: {
        origin: new origins.HttpOrigin(
          cdk.Fn.select(2, cdk.Fn.split("/", serverUrl.url))
        ),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        originRequestPolicy:
          cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
      },
      additionalBehaviors: {
        // Static assets from S3 — served directly, long TTL
        "_next/static/*": {
          origin: s3Origin,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        },
        // Image optimization
        "_next/image*": {
          origin: new origins.HttpOrigin(
            cdk.Fn.select(2, cdk.Fn.split("/", imageUrl.url))
          ),
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        },
        // Public assets
        "favicon.ico": {
          origin: s3Origin,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        },
      },
    });

    new cdk.CfnOutput(this, "DistributionUrl", {
      value: `https://${distribution.distributionDomainName}`,
    });
  }
}
```

---

## Next.js App Router Patterns

### Project Structure

```
my-nextjs-app/
├── app/
│   ├── layout.tsx           # Root layout (required)
│   ├── page.tsx             # Home page (/)
│   ├── loading.tsx          # Loading UI
│   ├── error.tsx            # Error boundary
│   ├── not-found.tsx        # 404 page
│   ├── api/
│   │   └── route.ts         # API route (/api)
│   ├── dashboard/
│   │   ├── layout.tsx       # Dashboard layout
│   │   ├── page.tsx         # Dashboard page
│   │   └── settings/
│   │       └── page.tsx     # Settings page
│   └── (marketing)/         # Route group (no URL impact)
│       ├── about/
│       │   └── page.tsx
│       └── contact/
│           └── page.tsx
├── components/
│   ├── ui/                  # shadcn/ui components
│   └── ...
├── lib/
│   ├── db.ts               # Database utilities
│   └── auth.ts             # Auth utilities
├── public/
├── next.config.ts
├── open-next.config.ts
├── tailwind.config.ts
└── infrastructure/
    └── lib/
        └── stack.ts
```

### Root Layout (Required)

```tsx
// app/layout.tsx
import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({ subsets: ["latin"] });

export const metadata: Metadata = {
  title: "My App",
  description: "My Next.js application",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className={inter.className}>{children}</body>
    </html>
  );
}
```

### Server Components (Default)

```tsx
// app/users/page.tsx
// This is a Server Component by default - no 'use client' directive

import { db } from "@/lib/db";

export default async function UsersPage() {
  // Direct database access - safe, credentials never sent to browser
  const users = await db.query.users.findMany();

  return (
    <div>
      <h1>Users</h1>
      <ul>
        {users.map((user) => (
          <li key={user.id}>{user.name}</li>
        ))}
      </ul>
    </div>
  );
}
```

### Client Components

```tsx
// components/counter.tsx
"use client"; // Required for interactivity

import { useState } from "react";

export function Counter() {
  const [count, setCount] = useState(0);

  return (
    <button onClick={() => setCount(count + 1)}>
      Count: {count}
    </button>
  );
}
```

### Loading UI (Streaming)

```tsx
// app/dashboard/loading.tsx
export default function Loading() {
  return (
    <div className="animate-pulse">
      <div className="h-8 bg-gray-200 rounded w-1/4 mb-4" />
      <div className="h-4 bg-gray-200 rounded w-full mb-2" />
      <div className="h-4 bg-gray-200 rounded w-3/4" />
    </div>
  );
}
```

### Error Boundary

```tsx
// app/dashboard/error.tsx
"use client"; // Error components must be Client Components

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="p-4 bg-red-50 rounded">
      <h2 className="text-red-800">Something went wrong!</h2>
      <button
        onClick={reset}
        className="mt-2 px-4 py-2 bg-red-600 text-white rounded"
      >
        Try again
      </button>
    </div>
  );
}
```

### Server Actions

```tsx
// app/actions.ts
"use server";

import { revalidatePath } from "next/cache";
import { db } from "@/lib/db";

export async function createUser(formData: FormData) {
  const name = formData.get("name") as string;
  const email = formData.get("email") as string;

  await db.insert(users).values({ name, email });

  // Revalidate the users page
  revalidatePath("/users");

  return { success: true };
}

export async function deleteUser(userId: string) {
  await db.delete(users).where(eq(users.id, userId));
  revalidatePath("/users");
}
```

### Using Server Actions in Forms

```tsx
// app/users/new/page.tsx
import { createUser } from "@/app/actions";

export default function NewUserPage() {
  return (
    <form action={createUser}>
      <input name="name" placeholder="Name" required />
      <input name="email" type="email" placeholder="Email" required />
      <button type="submit">Create User</button>
    </form>
  );
}
```

### Route Handlers (API Routes)

```tsx
// app/api/users/route.ts
import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db";

export async function GET(request: NextRequest) {
  const searchParams = request.nextUrl.searchParams;
  const limit = parseInt(searchParams.get("limit") || "10");

  const users = await db.query.users.findMany({ limit });

  return NextResponse.json(users);
}

export async function POST(request: NextRequest) {
  const body = await request.json();

  const user = await db.insert(users).values(body).returning();

  return NextResponse.json(user[0], { status: 201 });
}
```

### Dynamic Routes

```tsx
// app/users/[id]/page.tsx
import { notFound } from "next/navigation";
import { db } from "@/lib/db";

interface Props {
  params: Promise<{ id: string }>;
}

export default async function UserPage({ params }: Props) {
  const { id } = await params;
  const user = await db.query.users.findFirst({
    where: eq(users.id, id),
  });

  if (!user) {
    notFound();
  }

  return (
    <div>
      <h1>{user.name}</h1>
      <p>{user.email}</p>
    </div>
  );
}

// Generate static params for known users
export async function generateStaticParams() {
  const allUsers = await db.query.users.findMany({
    columns: { id: true },
  });

  return allUsers.map((user) => ({
    id: user.id,
  }));
}
```

### Metadata

```tsx
// app/users/[id]/page.tsx
import type { Metadata } from "next";

interface Props {
  params: Promise<{ id: string }>;
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;
  const user = await db.query.users.findFirst({
    where: eq(users.id, id),
  });

  return {
    title: user?.name ?? "User Not Found",
    description: `Profile page for ${user?.name}`,
    openGraph: {
      title: user?.name,
      images: [user?.avatarUrl].filter(Boolean),
    },
  };
}
```

### Middleware

```tsx
// middleware.ts (root level)
import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

export function middleware(request: NextRequest) {
  // Check authentication
  const token = request.cookies.get("auth-token");

  if (!token && request.nextUrl.pathname.startsWith("/dashboard")) {
    return NextResponse.redirect(new URL("/login", request.url));
  }

  // Add custom headers
  const response = NextResponse.next();
  response.headers.set("x-request-id", crypto.randomUUID());

  return response;
}

export const config = {
  matcher: [
    // Match all paths except static files
    "/((?!_next/static|_next/image|favicon.ico).*)",
  ],
};
```

---

## Caching and ISR

### Time-Based Revalidation

```tsx
// app/posts/page.tsx
export const revalidate = 60; // Revalidate every 60 seconds

export default async function PostsPage() {
  const posts = await fetch("https://api.example.com/posts", {
    next: { revalidate: 60 },
  }).then((res) => res.json());

  return (
    <ul>
      {posts.map((post) => (
        <li key={post.id}>{post.title}</li>
      ))}
    </ul>
  );
}
```

### On-Demand Revalidation with Tags

```tsx
// app/posts/page.tsx
export default async function PostsPage() {
  const posts = await fetch("https://api.example.com/posts", {
    next: { tags: ["posts"] },
  }).then((res) => res.json());

  return <PostList posts={posts} />;
}

// app/actions.ts
"use server";

import { revalidateTag } from "next/cache";

export async function createPost(formData: FormData) {
  // Create post...

  // Invalidate all pages using 'posts' tag
  revalidateTag("posts");
}
```

### CloudFront Cache Invalidation

```tsx
// app/actions.ts
"use server";

import { revalidatePath, revalidateTag } from "next/cache";
import {
  CloudFrontClient,
  CreateInvalidationCommand,
} from "@aws-sdk/client-cloudfront";

const cloudfront = new CloudFrontClient({});

export async function revalidateWithCloudFront(path: string) {
  // Revalidate Next.js cache
  revalidatePath(path);

  // Invalidate CloudFront cache
  await cloudfront.send(
    new CreateInvalidationCommand({
      DistributionId: process.env.CLOUDFRONT_DISTRIBUTION_ID,
      InvalidationBatch: {
        CallerReference: Date.now().toString(),
        Paths: {
          Quantity: 1,
          Items: [path],
        },
      },
    })
  );
}
```

---

## Environment Variables

### Next.js Environment Variables

```bash
# .env.local (not committed)
DATABASE_URL=postgres://...
AUTH_SECRET=...

# .env (committed, defaults)
NEXT_PUBLIC_API_URL=https://api.example.com
```

### CDK Environment Variables

```typescript
// infrastructure/lib/stack.ts
const nextjs = new Nextjs(this, "Nextjs", {
  nextjsPath: "../",
  environment: {
    // Server-side only (secure)
    DATABASE_URL: process.env.DATABASE_URL!,
    AUTH_SECRET: process.env.AUTH_SECRET!,

    // Public (exposed to browser)
    NEXT_PUBLIC_API_URL: "https://api.example.com",
  },
});
```

### Secrets Manager Integration

```tsx
// lib/secrets.ts
import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from "@aws-sdk/client-secrets-manager";

const client = new SecretsManagerClient({});
const secretCache = new Map<string, string>();

export async function getSecret(secretName: string): Promise<string> {
  if (secretCache.has(secretName)) {
    return secretCache.get(secretName)!;
  }

  const response = await client.send(
    new GetSecretValueCommand({ SecretId: secretName })
  );

  const secret = response.SecretString!;
  secretCache.set(secretName, secret);

  return secret;
}
```

---

## Streaming and Performance

### Enable Streaming in OpenNext

Lambda response streaming is available in all commercial AWS regions as of April 2026.

```typescript
// open-next.config.ts
const config: OpenNextConfig = {
  default: {
    override: {
      wrapper: "aws-lambda-streaming",
    },
  },
};
```

### Streaming Gotcha: Empty Body Hang

Lambda buffering can prevent streaming from starting when the initial response body is empty. Set the environment variable on your server function:

```typescript
environment: {
  OPEN_NEXT_FORCE_NON_EMPTY_RESPONSE: "true",
  // ... other env vars
},
```

Add this to `open-next.config.ts` environment as well if using the high-level construct.

### Suspense for Streaming

```tsx
// app/dashboard/page.tsx
import { Suspense } from "react";

export default function DashboardPage() {
  return (
    <div>
      <h1>Dashboard</h1>

      {/* This streams in immediately */}
      <Suspense fallback={<StatsSkeleton />}>
        <Stats />
      </Suspense>

      {/* This streams in when ready */}
      <Suspense fallback={<ChartSkeleton />}>
        <RevenueChart />
      </Suspense>
    </div>
  );
}

async function Stats() {
  const stats = await fetchStats(); // Slow API call
  return <StatsDisplay data={stats} />;
}
```

---

## Makefile

```makefile
.PHONY: build deploy dev clean

# Development
dev:
	npm run dev

# Build Next.js and OpenNext
build:
	npm run build
	npx open-next build

# Deploy to AWS
deploy: build
	cd infrastructure && npx cdk deploy --require-approval never

# Deploy with specific stack
deploy-prod: build
	cd infrastructure && npx cdk deploy ProdStack --require-approval never

# Clean build artifacts
clean:
	rm -rf .next .open-next node_modules/.cache

# Synth CDK (preview CloudFormation)
synth:
	cd infrastructure && npx cdk synth

# Diff CDK (show changes)
diff:
	cd infrastructure && npx cdk diff

# Destroy infrastructure
destroy:
	cd infrastructure && npx cdk destroy
```

---

## Common Issues

### Bundle Size Exceeds Lambda Limit

```typescript
// next.config.ts
const nextConfig = {
  experimental: {
    // Reduce bundle size
    optimizePackageImports: ["lodash", "@aws-sdk/*"],
  },
  // Exclude large optional dependencies
  webpack: (config) => {
    config.externals.push({
      "canvas": "commonjs canvas",
      "pdfjs-dist": "commonjs pdfjs-dist",
    });
    return config;
  },
};
export default nextConfig;
```

### ISR Not Revalidating

1. Check DynamoDB table exists with correct schema
2. Check SQS queue is FIFO with content-based deduplication
3. Verify environment variables are set correctly
4. Check CloudWatch logs for revalidation function errors

### Middleware Not Running on Cached Responses

```typescript
// open-next.config.ts
const config: OpenNextConfig = {
  middleware: {
    external: true, // Deploy to Lambda@Edge so it runs on every request
  },
};
```

**Note**: For simple request/response manipulation (header rewrites, geolocation-based redirects), CloudFront Functions are now the preferred pattern — sub-millisecond execution, and they have access to geolocation/CloudFront headers that Lambda@Edge Viewer Request lacks.

### Cold Starts Too Slow

1. Enable Lambda warming:
```typescript
// open-next.config.ts
const config: OpenNextConfig = {
  warmer: {
    invokeFunction: "aws-lambda",
  },
};
```

2. Reduce bundle size with minification:
```typescript
// open-next.config.ts
const config: OpenNextConfig = {
  default: {
    minify: true,
  },
};
```

3. Use ARM64 architecture (faster cold starts, ~20% cost reduction)

---

## Alternatives

| Option | When to choose |
|--------|---------------|
| **Vercel** | You don't need to own AWS infra; simplest DX; the Next.js Adapter API was designed for Vercel |
| **SST v3** | You want OpenNext + Pulumi/Terraform (SST moved off CDK in v3); strong DX |
| **AWS Amplify** | Managed Next.js hosting; Amplify's adapter is in active development via OpenNext |
| **`cdklabs/cdk-nextjs`** | CDK + public Adapter API; Next.js 16.2+ required; still 0.5 beta |
| **App Runner / ECS Fargate** | Long-running `next start` server; use `cdklabs/cdk-nextjs` container topologies |

If you don't need full AWS customization (VPC, fine-grained IAM, cost optimization, co-location with other Lambda workloads), Amplify or Vercel will be simpler to operate.

---

## Best Practices

### DO

- Use Server Components by default
- Add `'use client'` only when needed for interactivity
- Initialize database clients at module level (connection reuse)
- Use `revalidateTag` for fine-grained cache invalidation
- Enable streaming for faster Time to First Byte
- Use ARM64 architecture for Lambda (`lambda.Architecture.ARM_64`)
- Set appropriate memory (1024-2048 MB for server function)
- Use `NODEJS_22_X` runtime — `NODEJS_20_X` reached Lambda EOL 2026-04-30

### DON'T

- Don't use `'use client'` at the root layout
- Don't fetch data in Client Components when Server Components work
- Don't use `revalidate: 0` everywhere (defeats caching)
- Don't skip CloudFront invalidation after on-demand revalidation
- Don't store secrets in environment variables without encryption
- Don't deploy without testing ISR behavior locally
- Don't use `experimental.ppr` flag or `experimental_ppr` segment config — removed in Next.js 16
- Don't use deprecated `origins.S3Origin(bucket)` — use `origins.S3BucketOrigin.withOriginAccessControl(bucket)`

### Performance Checklist

- [ ] Using ARM64 Lambda architecture
- [ ] Runtime is `NODEJS_22_X` (not 20 or earlier)
- [ ] Server function memory >= 1024 MB
- [ ] Image optimization memory >= 1536 MB
- [ ] Streaming enabled for large pages
- [ ] `OPEN_NEXT_FORCE_NON_EMPTY_RESPONSE=true` set on server function
- [ ] Static assets served from S3 via CloudFront
- [ ] ISR configured with appropriate revalidation times
- [ ] CloudFront cache policies configured correctly
- [ ] Warming enabled for consistent latency

### Security Checklist

- [ ] Secrets in Secrets Manager, not environment variables
- [ ] Server Components for sensitive operations
- [ ] Middleware validates authentication
- [ ] API routes validate input
- [ ] CORS configured appropriately
- [ ] CloudFront configured with HTTPS only
