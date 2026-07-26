---
name: nextjs-deploy
description: Deploy Next.js applications to AWS Lambda using OpenNext and CDK. Use when deploying Next.js apps with App Router, Server Components, ISR, or streaming to AWS infrastructure.
---

# Next.js OpenNext AWS Deployment - Complete Reference

## Overview

Deploy Next.js applications to AWS using:
- **OpenNext**: Transforms Next.js build output for AWS Lambda
- **CDK**: Infrastructure as Code with TypeScript
- **Node.js 22** Lambda runtime (`NODEJS_22_X`): required; `NODEJS_20_X` reached Lambda EOL 2026-04-30

## Choosing a Construct (Start Here)

Three live options for deploying Next.js on AWS CDK as of 2026:

| Option | Package | Status | When to use |
|--------|---------|--------|-------------|
| `cdk-nextjs-standalone` (jetbridge) | npm | Stable, v4.x | Most projects today; mature, battle-tested, OpenNext v3/v4 |
| `cdklabs/cdk-nextjs` (AWS Labs) | npm | 0.5 beta | Next.js 16.2+ on the public Adapter API; AWS's strategic direction; not yet stable |
| Manual CDK | aws-cdk-lib | Always available | Full control; function splitting; custom routing logic |

**Pick `cdk-nextjs-standalone`** for new projects today unless you specifically need the public Adapter API topology options from `cdklabs/cdk-nextjs`. The AWS Labs construct is still in beta (0.5.0-beta) as of May 2026. Wait for stable before using in production.

**Future direction**: Next.js 16.2 shipped a stable public Adapter API in March 2026. OpenNext is rebuilding on it; `cdklabs/cdk-nextjs` uses it today. Expect a v5-era OpenNext paired with a stable `cdklabs/cdk-nextjs` to become the recommendation by late 2026.

---

## OpenNext v3 vs v4

`@opennextjs/aws` installs the latest by default: **v4.x as of May 2026**.

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

### Partial Prerendering (PPR): Now Default

PPR is default behavior under `cacheComponents: true`. No separate flag needed. Routes that mix static and dynamic content automatically benefit from shell-first streaming.

### Turbopack (Stable)

Turbopack is stable in Next.js 16. Use it for development to dramatically reduce rebuild times:
```bash
next dev --turbopack
```

OpenNext consumes the standard `.next` build output. Turbopack affects only the dev experience and build performance, not the Lambda artifact.

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

    // Server function: Node 22, ARM64
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

    // Image optimization function: Node 22, ARM64
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

    // Revalidation function: Node 22, ARM64
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
        // Static assets from S3: served directly, long TTL
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

**Note**: For simple request/response manipulation (header rewrites, geolocation-based redirects), CloudFront Functions are now the preferred pattern: sub-millisecond execution, and they have access to geolocation/CloudFront headers that Lambda@Edge Viewer Request lacks.

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
- Use `NODEJS_22_X` runtime: `NODEJS_20_X` reached Lambda EOL 2026-04-30

### DON'T

- Don't use `'use client'` at the root layout
- Don't fetch data in Client Components when Server Components work
- Don't use `revalidate: 0` everywhere (defeats caching)
- Don't skip CloudFront invalidation after on-demand revalidation
- Don't store secrets in environment variables without encryption
- Don't deploy without testing ISR behavior locally
- Don't use `experimental.ppr` flag or `experimental_ppr` segment config (removed in Next.js 16)
- Don't use deprecated `origins.S3Origin(bucket)`; use `origins.S3BucketOrigin.withOriginAccessControl(bucket)`

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

---

## Real-World CDK Patterns (Production Projects)

This section documents patterns mined directly from production codebases. Every snippet below was pulled from a running project.

### Construct Choice Across Projects

All projects use `cdk-opennext` (`NextjsSite` from `"cdk-opennext"`) or hand-rolled CDK. None use `cdk-nextjs-standalone` at the time of writing. The hand-rolled path (eleven9s admin) is chosen when you need precise IAM control or AASA file routing.

| Project | CDK approach | Notes |
|---------|-------------|-------|
| chadneal.com | `cdk-opennext` `NextjsSite` | ISR + DynamoDB cache, games served via static assets |
| regist | `cdk-opennext` `NextjsSite` | Includes `/api/*` → API Gateway CloudFront behavior |
| models-apresai | `cdk-opennext` `NextjsSite` | 4h EventBridge cron triggers revalidation endpoint |
| vail5r | `cdk-opennext` `NextjsSite` | Presigned S3 uploads, RBAC |
| dangerously-skip | `cdk-opennext` `NextjsSite` | Smallest reference project |
| eleven9s admin | Hand-rolled CDK | Full IAM control, AASA route, streaming invoke mode |
| sophie | Hand-rolled CDK | API Gateway HTTP API origin, custom security headers policy |

### cdk-opennext: Minimal Production Instantiation

```typescript
// chadneal.com: chadneal-web/cdk/lib/chadneal-stack.ts
import { NextjsSite } from "cdk-opennext";

const site = new NextjsSite(this, "NextjsSite", {
  openNextPath: ".open-next",

  customDomain: {
    domainName: "www.chadneal.com",
    hostedZone,          // route53.HostedZone.fromHostedZoneAttributes(...)
    certificate,         // acm.Certificate.fromCertificateArn(...)
  },

  defaultFunctionProps: {
    memorySize: 2048,
    timeout: Duration.seconds(30),
    environment: {
      HIGH_SCORES_TABLE_NAME: highScoresTable.tableName,
      AUTH_SECRET: authSecret,
      NEXTAUTH_URL: "https://www.chadneal.com",
      GOOGLE_CLIENT_ID: googleClientId,
      GOOGLE_CLIENT_SECRET: googleClientSecret,
    },
  },

  warm: 1,
  warmerInterval: Duration.minutes(5),
});

// Grant DynamoDB access to the server function
highScoresTable.grantReadWriteData(site.defaultServerFunction);
```

**cdk-opennext exposes `site.defaultServerFunction`**. Use it for `table.grantReadWriteData(...)` and `bucket.grantReadWrite(...)` instead of constructing ARNs manually.

### Disabling CloudFront SSR Caching (Required Pattern)

The `NextjsSite` construct wires a caching policy to the default behavior. Override it to `CachingDisabled` so Next.js cache-control headers take effect:

```typescript
// Used in chadneal.com, regist, vail5r, dangerously-skip
const cfnDistribution = site.distribution!.node
  .defaultChild as cloudfront.CfnDistribution;

cfnDistribution.addPropertyOverride(
  "DistributionConfig.DefaultCacheBehavior.CachePolicyId",
  "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" // Managed-CachingDisabled
);
```

This is an escape hatch on the L1 construct. Without it, CloudFront caches all SSR responses indefinitely regardless of `Cache-Control` headers.

### Adding an API Gateway Behavior to the Same CloudFront Distribution

Regist co-locates the Next.js frontend and Go API behind one CloudFront distribution. A CloudFront Function strips `/api` before forwarding:

```typescript
// regist/infrastructure/lib/regist-stack.ts

// CloudFront Function: strips /api prefix
const apiRewriteFn = new cloudfront.Function(this, "ApiRewriteFn", {
  functionName: "regist-api-rewrite",
  code: cloudfront.FunctionCode.fromInline(`
function handler(event) {
  var request = event.request;
  request.uri = request.uri.replace(/^\\/api/, '');
  if (request.uri === '') request.uri = '/';
  return request;
}
  `.trim()),
});

const apiOrigin = new cloudfrontOrigins.HttpOrigin(
  cdk.Fn.select(2, cdk.Fn.split("/", httpApi.apiEndpoint)),
  { protocolPolicy: cloudfront.OriginProtocolPolicy.HTTPS_ONLY }
);

site.distribution!.addBehavior("/api/*", apiOrigin, {
  viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
  allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
  cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
  originRequestPolicy:
    cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
  functionAssociations: [
    {
      function: apiRewriteFn,
      eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
    },
  ],
});
```

### Hand-Rolled CDK with Streaming Invoke Mode (eleven9s Admin)

When you need fine-grained IAM, use the manual path. Note `invokeMode: lambda.InvokeMode.RESPONSE_STREAM` on the server function URL; this enables Lambda response streaming for reduced TTFB:

```typescript
// eleven9s/infrastructure/lib/admin-stack.ts (simplified)
const serverFn = new lambda.Function(this, "ServerFunction", {
  functionName: "eleven9s-admin-server",
  runtime: lambda.Runtime.NODEJS_22_X,
  architecture: lambda.Architecture.ARM_64,
  handler: "index.handler",
  code: lambda.Code.fromAsset(path.join(openNext, "server-functions/default")),
  memorySize: 1024,
  timeout: cdk.Duration.seconds(30),
  role: adminRole,
  environment: {
    CACHE_BUCKET_NAME: assetsBucket.bucketName,
    CACHE_BUCKET_KEY_PREFIX: "_cache",
    CACHE_BUCKET_REGION: this.region,
    CACHE_DYNAMO_TABLE: tagCacheTable.tableName,
    REVALIDATION_QUEUE_URL: revalidationQueue.queueUrl,
    REVALIDATION_QUEUE_REGION: this.region,
    OPEN_NEXT_FORCE_NON_EMPTY_RESPONSE: "true",
    NEXTAUTH_URL: `https://${props.domainName}`,
  },
  logRetention: logs.RetentionDays.TWO_WEEKS,
});

const serverUrl = serverFn.addFunctionUrl({
  authType: lambda.FunctionUrlAuthType.NONE,
  invokeMode: lambda.InvokeMode.RESPONSE_STREAM,  // <-- enables streaming
});

// origins.FunctionUrlOrigin wraps Lambda Function URLs cleanly
const serverOrigin = new origins.FunctionUrlOrigin(serverUrl);
```

The eleven9s admin stack also deploys the OpenNext cache snapshot at deploy time:

```typescript
new s3deploy.BucketDeployment(this, "DeployCache", {
  sources: [s3deploy.Source.asset(path.join(openNext, "cache"))],
  destinationBucket: assetsBucket,
  destinationKeyPrefix: "_cache",
  memoryLimit: 512,
  prune: false,  // never prune: cache entries must persist across deploys
});
```

### Lambda Warming via EventBridge (Standard Pattern)

All projects use the same shape: EventBridge rate rule every 5 minutes targeting the warmer function. With `cdk-opennext`, pass `warm: 1, warmerInterval: Duration.minutes(5)` to the `NextjsSite` construct and it handles this automatically. For the hand-rolled path (sophie, models-apresai):

```typescript
// sophie-web/infrastructure/lib/sophie-web-stack.ts (simplified)
const warmerFunction = new lambda.Function(this, "WarmerFunction", {
  functionName: "sophie-web-warmer-prod",
  runtime: lambda.Runtime.NODEJS_24_X,
  architecture: lambda.Architecture.ARM_64,
  handler: "index.handler",
  code: lambda.Code.fromAsset(
    path.join(__dirname, "../../.open-next/warmer-function")
  ),
  memorySize: 128,
  timeout: cdk.Duration.seconds(30),
  environment: {
    // WARM_PARAMS is a JSON array: [{concurrency, function}]
    // Confirmed from .open-next/warmer-function/index.mjs
    WARM_PARAMS: JSON.stringify([
      { concurrency: 3, function: serverFunction.functionName },
    ]),
  },
});

serverFunction.grantInvoke(warmerFunction);

new events.Rule(this, "WarmerRule", {
  ruleName: "sophie-web-warmer-prod",
  schedule: events.Schedule.rate(cdk.Duration.minutes(5)),
  targets: [new eventsTargets.LambdaFunction(warmerFunction)],
});
```

`concurrency: 3` keeps 3 instances warm. Cost: ~$0.19/month. Set to 1 for low-traffic sites.

### Cost Tags via CDK App-Level Aspects (Standard Schema)

Apply tags at the `cdk.App()` level so every resource in every stack is tagged uniformly. Taken directly from dangerously-skip:

```typescript
// cdk/bin/app.ts
const app = new cdk.App();

new DangerouslySkipStack(app, "DangerouslySkipStack", { env });
new GitHubOidcStack(app, "GitHubOidcStack", { env });

// Standard cost tag schema: applies to every resource in both stacks
cdk.Tags.of(app).add("project", "dangerously-skip");
cdk.Tags.of(app).add("env", "prod");
cdk.Tags.of(app).add("managed-by", "cdk");
cdk.Tags.of(app).add("owner", "chad");
```

The four canonical tags are `project`, `env`, `managed-by`, and `owner`. See `obsidian:resources/aws-cost-tagging.md` for the full cost allocation setup.

### GitHub OIDC Stack (Keyless CI Deploys)

No long-lived AWS access keys in CI. The OIDC provider lets GitHub Actions assume a role using a short-lived token:

```typescript
// dangerously-skip/cdk/lib/github-oidc-stack.ts
const provider = new iam.OpenIdConnectProvider(this, "GitHubOidc", {
  url: "https://token.actions.githubusercontent.com",
  clientIds: ["sts.amazonaws.com"],
});

const role = new iam.Role(this, "GitHubActionsDeployRole", {
  roleName: "github-actions-dangerously-skip-deploy",
  maxSessionDuration: cdk.Duration.hours(1),
  assumedBy: new iam.WebIdentityPrincipal(
    provider.openIdConnectProviderArn,
    {
      StringEquals: {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      },
      StringLike: {
        "token.actions.githubusercontent.com:sub":
          "repo:apresai/dangerously-skip:ref:refs/heads/main",
      },
    }
  ),
});
```

Reference this role ARN in your GitHub Actions workflow under `role-to-assume`.

### EventBridge Cron for Background Workers (models-apresai)

The models-apresai collector runs every 4 hours and calls the Next.js `/api/revalidate` endpoint afterward, a clean pattern for decoupling data collection from page rendering:

```typescript
// models-apresai/infrastructure/lib/models-apresai-stack.ts
new events.Rule(this, "CollectorSchedule", {
  ruleName: "models-apresai-collector-cron",
  description: "Run the collector every 4 hours (00/04/08/12/16/20 UTC)",
  schedule: events.Schedule.expression("cron(0 0,4,8,12,16,20 * * ? *)"),
  targets: [new targets.LambdaFunction(collectorFn)],
});
```

The collector Lambda posts to `https://${domainName}/api/revalidate` with a bearer token, triggering `revalidateTag(...)` inside the Next.js route handler. The site then also calls `cloudfront.CreateInvalidation` on `/api/*` to bust CloudFront's edge cache independently of the Next.js ISR layer.

### Apex Domain + www via L1 Escape Hatch

`cdk-opennext` only accepts one `domainName`. To serve both apex and www, patch the CloudFront L1 construct and add a second Route53 record:

```typescript
// chadneal-web/cdk/lib/chadneal-stack.ts
cfnDistribution.addPropertyOverride("DistributionConfig.Aliases", [
  "www.chadneal.com",
  "chadneal.com",
]);

new route53.ARecord(this, "ApexARecord", {
  zone: hostedZone,
  recordName: "chadneal.com",
  target: route53.RecordTarget.fromAlias(
    new targets.CloudFrontTarget(site.distribution)
  ),
});

new route53.AaaaRecord(this, "ApexAaaaRecord", {
  zone: hostedZone,
  recordName: "chadneal.com",
  target: route53.RecordTarget.fromAlias(
    new targets.CloudFrontTarget(site.distribution)
  ),
});
```

Always create both A and AAAA records (IPv4 + IPv6).

### Runtime Audit in Makefile (models-apresai pattern)

Every project's `make deploy` should gate on a runtime audit. The models-apresai Makefile shows the exact grep:

```makefile
audit:
	@echo ">> auditing Lambda runtime/arch invariants"
	@! grep -RnE 'NODEJS_(16|18|20)_X|Architecture\.X86_64' . \
		--include='*.ts' --include='*.js' \
		--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=cdk.out \
		--exclude-dir=.next --exclude-dir=.open-next --exclude-dir=dist 2>/dev/null \
		|| (echo "AUDIT FAILED: forbidden Lambda runtime/arch found above" && exit 1)
	@echo "OK"

deploy: audit build build-opennext cdk-install
	cd infrastructure && npx cdk deploy --require-approval never
```

This blocks any deploy that introduces `NODEJS_16_X`, `NODEJS_18_X`, `NODEJS_20_X`, or `Architecture.X86_64`.

---

## Authentication Patterns

### Pattern 1: Server Components + `auth()` Only (No Middleware, No Lambda@Edge)

This is the eleven9s admin portal pattern. It is the recommended approach for internal tools and admin portals where every page requires authentication.

**Why not middleware?**

Next.js middleware runs in the Edge runtime by default. On Lambda/OpenNext, deploying middleware as `external: true` requires Lambda@Edge, adding cost, cold starts, and SDK compatibility constraints. For an admin portal where every route is protected, calling `auth()` directly in each Server Component is simpler and runs entirely in the existing Node.js Lambda.

```typescript
// eleven9s/admin/src/lib/auth.ts
import NextAuth, { type NextAuthConfig } from "next-auth";
import Google from "next-auth/providers/google";
import { getRuntimeConfig } from "./runtimeConfig";

// Top-level await works in Node 20+ ESM. Config is fetched from SSM
// once at cold start and reused for the Lambda's lifetime.
const config = await getRuntimeConfig();

export const { handlers, auth, signIn, signOut } = NextAuth({
  trustHost: true, // Required behind CloudFront / Lambda Function URL
  secret: config.nextauthSecret,
  session: { strategy: "jwt" },
  providers: [
    Google({
      clientId: config.googleClientId,
      clientSecret: config.googleClientSecret,
      allowDangerousEmailAccountLinking: true,
    }),
  ],
  pages: { signIn: "/login", error: "/login" },
  callbacks: {
    async signIn({ user }) {
      // Allowlist check: only permitted emails can sign in
      return config.allowedEmails
        .map((e) => e.toLowerCase())
        .includes((user.email ?? "").toLowerCase());
    },
    async session({ session }) {
      return session;
    },
  },
} satisfies NextAuthConfig);
```

```tsx
// eleven9s/admin/src/app/page.tsx
import { redirect } from "next/navigation";
import { auth } from "@/lib/auth";
import { getDashboardStats } from "@/lib/dashboardData";

export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  // auth() is called in every protected Server Component.
  // No middleware, no Lambda@Edge.
  const session = await auth();
  if (!session?.user) redirect("/login");

  const stats = await getDashboardStats();
  return <AdminShell session={session}>...</AdminShell>;
}
```

The login page uses a Server Action to call `signIn()`:

```tsx
// eleven9s/admin/src/app/login/page.tsx
import { signIn } from "@/lib/auth";

export default async function LoginPage({ searchParams }) {
  const { callbackUrl } = await searchParams;
  return (
    <form
      action={async () => {
        "use server";
        await signIn("google", { redirectTo: callbackUrl ?? "/" });
      }}
    >
      <button type="submit">Continue with Google</button>
    </form>
  );
}
```

**Credentials from SSM at cold start**: The `getRuntimeConfig()` function calls SSM `GetParameters` on first invocation and caches the result in module scope. This avoids baking secrets into Lambda environment variables while keeping latency minimal (SSM call only happens on cold start).

### Pattern 2: NextAuth.js v5 (Beta) with Google OAuth + Backend Token Exchange

Used in sophie, chadneal.com, podcaster, vail5r. The web app authenticates with Google, then exchanges the Google ID token for backend-issued JWT tokens. This lets the mobile and web clients use the same token format.

```typescript
// podcaster/portal/src/lib/auth.ts (condensed)
import "server-only";
import NextAuth from "next-auth";
import type { NextAuthConfig } from "next-auth";
import Google from "next-auth/providers/google";

declare module "next-auth" {
  interface Session {
    user: { id: string; email: string; name: string; role: string; status: string; };
    error?: string;
  }
}

const SESSION_MAX_AGE = 365 * 24 * 60 * 60;

export const authConfig: NextAuthConfig = {
  trustHost: true,                    // Required for Lambda/CloudFront
  providers: [
    Google({
      clientId: process.env.GOOGLE_CLIENT_ID!,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET!,
      checks: ["none"],               // Disable PKCE (not needed for server-side)
      authorization: {
        params: {
          prompt: "consent",
          access_type: "offline",     // Get refresh token
          response_type: "code",
        },
      },
    }),
  ],
  session: {
    strategy: "jwt",
    maxAge: SESSION_MAX_AGE,
  },
  cookies: {
    sessionToken: {
      name: process.env.NODE_ENV === "production"
        ? "__Secure-authjs.session-token"
        : "authjs.session-token",
      options: { httpOnly: true, sameSite: "lax", path: "/", secure: true },
    },
  },
  callbacks: {
    async jwt({ token, account }) {
      if (account) {
        // Initial sign-in: capture tokens from Google
        return {
          ...token,
          access_token: account.access_token,
          refresh_token: account.refresh_token,
          expires_at: account.expires_at,
        };
      }
      if (token.expires_at && Date.now() < token.expires_at * 1000) {
        return token; // Token still valid
      }
      // Token expired: refresh via Google
      const res = await fetch("https://oauth2.googleapis.com/token", {
        method: "POST",
        body: new URLSearchParams({
          grant_type: "refresh_token",
          client_id: process.env.GOOGLE_CLIENT_ID!,
          client_secret: process.env.GOOGLE_CLIENT_SECRET!,
          refresh_token: token.refresh_token as string,
        }),
      });
      const data = await res.json();
      if (!res.ok) return { ...token, error: "RefreshAccessTokenError" };
      return { ...token, access_token: data.access_token,
               expires_at: Math.floor(Date.now() / 1000) + data.expires_in };
    },
    session: sessionCallback, // stamps role/status from DynamoDB onto session
  },
  pages: { signIn: "/login" },
};

export const { handlers, auth, signIn, signOut } = NextAuth(authConfig);
```

**Cookie naming with `__Secure-` prefix**: Use `__Secure-authjs.session-token` in production, not `__Host-`. CloudFront strips the `Path` attribute that `__Host-` requires, causing silent auth failures. All projects use `__Secure-` (or `__Secure-next-auth.session-token` on older NextAuth naming).

**RBAC via session callback**: The podcaster pattern stamps `role` and `status` from DynamoDB onto the session in `sessionCallback`. Downstream checks do `session.user.role !== "admin"`; they never trust a client-supplied role claim.

```typescript
// podcaster/portal/src/lib/auth-callbacks.ts
export async function sessionCallback({ session, token }) {
  if (session.user?.email) {
    const dbUser = await getUserByEmail(session.user.email);
    if (dbUser) {
      session.user.id = dbUser.userId;
      session.user.role = dbUser.role;   // "user" | "creator" | "admin"
      session.user.status = dbUser.status;
    } else {
      session.error = "UserNotFound";
      session.user.role = "";
    }
  }
  return session;
}
```

**Sophie's more complex pattern**: Sophie exchanges the Google ID token for Go-backend-issued JWT tokens (separate `accessToken` and `refreshToken`). This lets the mobile app and web app share the same token validation logic. See `/Users/chad/dev/sophie/sophie-web/auth.ts` for the full multi-tab token refresh coordination pattern with `acquireRefreshLock()`.

### Pattern 3: Custom JWT (Go Backend Issues Tokens, Web Validates)

Used in regist. The Go API issues JWTs stored in AWS Secrets Manager. The Next.js frontend validates these tokens server-side without Cognito or NextAuth.

```typescript
// regist/infrastructure/lib/regist-stack.ts: JWT secret setup
const jwtSecret = new secretsmanager.Secret(this, "JwtSecret", {
  secretName: "regist-jwt-secret",
  generateSecretString: {
    secretStringTemplate: "{}",
    generateStringKey: "secret",
    passwordLength: 64,
    excludePunctuation: true,
  },
});

// The auth Lambda reads this secret, issues JWTs, and vends
// short-lived STS credentials for direct DynamoDB/S3 access from iOS.
const authFn = new lambda.Function(this, "AuthFunction", {
  environment: {
    JWT_SECRET_ARN: jwtSecret.secretArn,
    STS_ROLE_ARN: iosSdkRole.roleArn,     // iOS client assumes this role
    GOOGLE_CLIENT_IDS: googleClientIDs,
  },
});
jwtSecret.grantRead(authFn);
```

The web frontend passes the JWT as a cookie to the Go API (`INTERNAL_API_URL` is the API Gateway endpoint, set as a Lambda environment variable):

```typescript
// regist NextjsSite environment
defaultFunctionProps: {
  environment: {
    INTERNAL_API_URL: httpApi.apiEndpoint,  // direct APIGW, no CloudFront
  },
},
```

---

## ISR and Caching Patterns

### ISR Infrastructure: Two S3 Buckets + DynamoDB + SQS FIFO Queue

OpenNext ISR requires four resources. The naming and schema matter:

```typescript
// sophie-web/infrastructure/lib/sophie-web-stack.ts: ISR setup
const cacheBucket = new s3.Bucket(this, "CacheBucket", {
  bucketName: `sophie-web-cache-prod-${this.account}`,
  lifecycleRules: [
    { expiration: cdk.Duration.days(7), prefix: "_cache/" },
  ],
});

const cacheTable = new dynamodb.Table(this, "CacheTable", {
  tableName: "sophie-web-cache-prod",
  partitionKey: { name: "path", type: dynamodb.AttributeType.STRING },
  sortKey: { name: "tag", type: dynamodb.AttributeType.STRING },
  billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
  timeToLiveAttribute: "ttl",
});
cacheTable.addGlobalSecondaryIndex({
  indexName: "revalidate",
  partitionKey: { name: "path", type: dynamodb.AttributeType.STRING },
  sortKey: { name: "revalidatedAt", type: dynamodb.AttributeType.NUMBER },
});

const revalidationQueue = new sqs.Queue(this, "RevalidationQueue", {
  queueName: "sophie-web-revalidation-prod.fifo",
  fifo: true,
  contentBasedDeduplication: true,
  visibilityTimeout: cdk.Duration.seconds(60),
  retentionPeriod: cdk.Duration.days(1),
});
```

The DynamoDB GSI name must be `revalidate` (lowercase): OpenNext looks for this index by name.

**When to use `revalidate: 0` vs. ISR**: Use `revalidate: 0` (or `export const dynamic = "force-dynamic"`) for pages that must be fresh on every request: admin dashboards, user-specific data, anything that reads from session. Use ISR with a positive revalidation interval for public content that can tolerate stale data (blog posts, product listings, public stats).

### Externally-Triggered Revalidation (models-apresai Pattern)

The collector Lambda calls a protected Next.js route to invalidate specific tags after a data update:

```typescript
// Next.js route: app/api/revalidate/route.ts
import { revalidateTag } from "next/cache";
import { NextRequest, NextResponse } from "next/server";

export async function POST(req: NextRequest) {
  const auth = req.headers.get("authorization");
  if (auth !== `Bearer ${process.env.REVALIDATE_TOKEN}`) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  const { tag } = await req.json();
  revalidateTag(tag);
  return NextResponse.json({ revalidated: true });
}
```

The `REVALIDATE_TOKEN` is generated by CDK (`generateSecretString`) and injected into both the site Lambda and the collector Lambda environment. After calling the Next.js endpoint, the collector also calls `cloudfront.CreateInvalidation` on `/api/*` to bust CloudFront's own edge cache.

---

## OpenAPI-First Workflow (sophie, regist, eleven9s)

### Pattern: Single Spec, Generated Types for Every Consumer

Sophie maintains one `openapi/spec/openapi.yaml` and generates types for Go (server), TypeScript (web), and Dart (mobile) from it. The eleven9s pattern extends this to Swift.

```makefile
# sophie/Makefile: type generation targets
generate-types:
	# Step 1: Go types
	cd sophie-api/openapi && $(MAKE) generate-go
	# Step 2: TypeScript types
	cd sophie-api/openapi && $(MAKE) generate-ts
	# Step 3: Distribute to consumers
	cp sophie-api/openapi/generated/typescript/types.ts ../sophie-web/types/api.ts

# Ensure types are in sync before deploy
check-sync:
	# Regenerate in a temp dir and diff against committed types
	$(MAKE) generate-types > /dev/null 2>&1
	diff -r .generated-backup openapi/generated || (echo "Types out of sync, run make generate-types"; exit 1)
```

```makefile
# eleven9s/Makefile: generates TypeScript for the admin Next.js app
gen-admin-types:
	cd admin && npx openapi-typescript ../openapi/admin-api.yaml -o src/api/types.ts
```

### Spec-First Deploy Guard (sophie)

Sophie blocks deploys on uncommitted changes; pre-commit hooks validate that `generate-types` was run:

```makefile
deploy: $(SCHEMA_MARKER)
	@if ! git diff --quiet HEAD 2>/dev/null; then \
		echo "Deploy blocked: uncommitted changes detected"; \
		echo "Commit first so pre-commit hooks validate your code."; \
		exit 1; \
	fi
	cd sophie-api && $(MAKE) deploy
	cd sophie-web && $(MAKE) deploy
	sophie-api/scripts/verify-lambda-env.sh
```

---

## Makefile Patterns

All projects follow the same target conventions:

```makefile
# Standard Makefile structure
.PHONY: clean build deploy dev

clean:
	rm -rf .next .open-next cdk.out node_modules/.cache

build:
	npm run build          # Next.js build
	npx open-next build    # Produces .open-next/

# Load .env.production before CDK so secrets reach Lambda env vars
deploy: clean build
	@if [ -f .env.production ]; then \
		set -a && . ./.env.production && set +a && \
		cd infrastructure && npx cdk deploy --require-approval never; \
	else \
		echo "Error: .env.production not found"; exit 1; \
	fi

dev:
	npm run dev

# CDK-only shortcut (skips next.js rebuild, useful when only infra changed)
diff:
	cd infrastructure && npx cdk diff

synth:
	cd infrastructure && npx cdk synth
```

For monorepos (regist, models-apresai) where the CDK project is a sibling directory:

```makefile
# models-apresai pattern: explicit build chain
build-opennext: build-web
	cd web && npx open-next build     # writes web/.open-next/

deploy: audit build build-opennext cdk-install
	cd infrastructure && npx cdk deploy --require-approval never
```

**The `.env.production` convention**: Secrets are stored in a gitignored `.env.production` file at the project root. The Makefile sources it with `set -a && . ./.env.production && set +a` so environment variables are available when CDK reads `process.env.*` at synth time. This is how `AUTH_SECRET`, `GOOGLE_CLIENT_ID`, etc. reach the Lambda `environment` block.

---

## Worktree Gotcha: CDK Synth Fails Without Build Artifacts

Fresh worktrees created with `claude -w <slug>` do not contain `.open-next/` because it is gitignored. CDK's `lambda.Code.fromAsset(path.join(openNext, "server-functions/default"))` reads from disk at synth time to hash the artifact for CloudFormation logical IDs. Synth fails with "path does not exist."

**Four options (choose one per situation):**

1. **Code-only PRs (default)**: Run `npx tsc --noEmit -p infrastructure/` instead of `cdk synth`. TypeScript compile catches type errors without needing build artifacts. Use this for tag additions, comment edits, renames.

2. **Structural validation**: Run `make build && cdk synth && cdk diff` in the worktree. This runs the full build chain, produces `.open-next/`, then synths. Required when the PR adds/removes a Lambda or moves an asset path.

3. **CI placeholder pattern** (eleven9s reference): Before `cdk synth --quiet` in CI, write placeholder bytes to each asset path. This lets synth hash dummy files without rebuilding.
   ```bash
   mkdir -p web/.open-next/server-functions/default
   printf "placeholder" > web/.open-next/server-functions/default/index.js
   npx cdk synth --quiet
   ```

4. **`make bootstrap` target**: Each project's Makefile should have a `bootstrap` target that runs `npm ci` in each package and executes a first build. Run after `git worktree add` to prime the worktree.

See `obsidian:resources/cdk-worktree-build-norms.md` for the canonical reference.

---

## Security Headers (Production Pattern from Sophie)

Sophie uses a `ResponseHeadersPolicy` construct for Lighthouse compliance. This is worth reusing:

```typescript
// sophie-web/infrastructure/lib/sophie-web-stack.ts (condensed)
const responseHeadersPolicy = new cloudfront.ResponseHeadersPolicy(
  this,
  "SecurityHeadersPolicy",
  {
    securityHeadersBehavior: {
      strictTransportSecurity: {
        accessControlMaxAge: cdk.Duration.seconds(31536000), // 1 year
        includeSubdomains: true,
        preload: true,
        override: true,
      },
      contentTypeOptions: { override: true }, // nosniff
      frameOptions: {
        frameOption: cloudfront.HeadersFrameOption.DENY,
        override: true,
      },
      referrerPolicy: {
        referrerPolicy:
          cloudfront.HeadersReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN,
        override: true,
      },
    },
  }
);
```

Apply to the default behavior and all additional behaviors. The eleven9s admin stack uses `cloudfront.ResponseHeadersPolicy.SECURITY_HEADERS` (the built-in managed policy) for simpler setups.

---

## Common Errors and Fixes

### `path does not exist` during CDK synth

**Cause**: `.open-next/` or `build/` artifacts do not exist in the worktree. CDK hashes these at synth time.

**Fix**: Run `make build` (or `make build-opennext`) before `cdk synth`. In CI, use placeholder bytes (see Worktree Gotcha section).

### SSR responses cached by CloudFront

**Cause**: `cdk-opennext` wires a default caching policy to the CloudFront default behavior. All SSR responses get cached regardless of `Cache-Control`.

**Fix**: Override to the managed `CachingDisabled` policy:
```typescript
cfnDistribution.addPropertyOverride(
  "DistributionConfig.DefaultCacheBehavior.CachePolicyId",
  "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
);
```

### Auth cookies dropped or not set

**Cause 1**: `__Host-` cookie prefix requires `Path=/` and `Secure` to be set by the same origin. CloudFront strips or modifies `Set-Cookie` headers in ways that violate `__Host-` constraints.

**Fix**: Use `__Secure-` prefix instead. Both eleven9s and podcaster use this.

**Cause 2**: `trustHost: true` not set. NextAuth v5 requires this when running behind a proxy (CloudFront, API Gateway).

**Fix**: Add `trustHost: true` to the NextAuth config.

### Lambda cold start hangs on first byte

**Cause**: Lambda response streaming is enabled but the initial response body is empty. Lambda's buffering layer waits for content before flushing.

**Fix**: Set `OPEN_NEXT_FORCE_NON_EMPTY_RESPONSE: "true"` in the server function environment. This is set in eleven9s admin, and should be set in all streaming deployments.

### ISR revalidation not triggering

**Cause 1**: DynamoDB GSI not named `revalidate` (exact match required by OpenNext).

**Cause 2**: SQS queue is not FIFO or `contentBasedDeduplication` is false.

**Cause 3**: Revalidation function missing `CACHE_DYNAMO_TABLE` environment variable.

**Fix**: Cross-check against the eleven9s admin or sophie ISR setup above.

### NextAuth `NEXTAUTH_URL` mismatch

**Cause**: `NEXTAUTH_URL` must match the exact domain the app is served on, including the `https://` scheme. If CloudFront is in front, set it to the CloudFront or custom domain, not the Lambda Function URL.

**Fix**: Set `NEXTAUTH_URL: "https://your-domain.com"` in the Lambda environment. Also set `trustHost: true`.

### `site.defaultServerFunction` undefined

**Cause**: Accessing `site.defaultServerFunction` before the `NextjsSite` construct has fully initialized, or the property name changed in a newer version of `cdk-opennext`.

**Fix**: Check the installed version of `cdk-opennext`. The property is `defaultServerFunction` on recent versions. Grant permissions after the construct is fully initialized.

---

## Checklist Additions

### Deployment Checklist

- [ ] Run `make audit`: no `NODEJS_(16|18|20)_X` or `Architecture.X86_64` in CDK code
- [ ] `.env.production` sourced before `cdk deploy` (secrets reach Lambda environment)
- [ ] `OPEN_NEXT_FORCE_NON_EMPTY_RESPONSE=true` set on server function
- [ ] `NEXTAUTH_URL` matches the deployed domain exactly
- [ ] `trustHost: true` in NextAuth config
- [ ] CloudFront default behavior overridden to `CachingDisabled` (if using `cdk-opennext`)
- [ ] Cost tags applied at `cdk.App()` level: `project`, `env`, `managed-by`, `owner`
- [ ] Lambda warming configured (1 instance every 5 min minimum)
- [ ] Both A and AAAA Route53 records created for custom domain
- [ ] `prune: false` on cache `BucketDeployment` (never prune ISR cache entries)
