# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Claude Code plugin marketplace repository maintained by apresai. It provides production-ready skills and plugins for Claude Code.

### Current Plugins

**nova-act-skill**: Generate production-ready Amazon Nova Act Python scripts for browser automation. Nova Act is Amazon's AI-powered browser automation SDK that uses natural language commands combined with Python code to create reliable web workflows.

**Key Philosophy**: Break automation tasks into multiple small `act()` calls rather than one large end-to-end prompt. This increases reliability and maintainability.

## Repository Structure

```
apresai-skills-marketplace/
├── .claude-plugin/
│   └── marketplace.json          # Marketplace configuration
├── plugins/
│   └── nova-act-skill/           # Nova Act browser automation skill
│       ├── .claude-plugin/
│       │   └── plugin.json       # Plugin manifest
│       ├── skills/
│       │   └── nova-act-builder/
│       │       └── SKILL.md      # Complete Nova Act API reference (~20KB)
│       ├── README.md             # Plugin overview and usage guide
│       ├── QUICKSTART.md         # 5-minute getting started guide
│       ├── OVERVIEW.md           # Detailed package contents
│       ├── config_template.py    # Configuration template
│       └── examples/
│           ├── 01_price_comparison.py
│           ├── 02_form_filling.py
│           └── 03_monitoring_alerts.py
├── README.md                      # Marketplace overview
├── CLAUDE.md                      # This file
└── LICENSE
```

## nova-act-skill Plugin Documentation

### Core Documents (in plugins/nova-act-skill/)

- **skills/nova-act-builder/SKILL.md**: Primary skill reference containing complete Nova Act API documentation, all initialization parameters, best practices, security patterns, and script generation guidelines. Read this first when generating Nova Act scripts.

- **README.md**: Package overview explaining what's included, how Claude users should reference the skill, and how developers should use it.

- **QUICKSTART.md**: Installation and setup guide with common troubleshooting steps.

- **OVERVIEW.md**: Detailed descriptions of all package contents and learning paths.

- **config_template.py**: Production-ready configuration template with environment settings, browser configs, proxy setup, AWS integration, and notification settings.

### Example Scripts

All examples demonstrate production-ready patterns:

1. **01_price_comparison.py**: Parallel execution with ThreadPoolExecutor, Pydantic schemas for data extraction, concurrent browser sessions across multiple retailers (Amazon, Best Buy, Target).

2. **02_form_filling.py**: Persistent browser sessions with `user_data_dir`, captcha detection and human intervention, secure password entry with getpass, file uploads via Playwright, screenshot verification.

3. **03_monitoring_alerts.py**: Headless automation, state persistence across runs, scheduled execution, change detection algorithms, alert triggering.

## Nova Act Script Generation Guidelines

When generating Nova Act scripts for users, follow these patterns:

### Required Script Structure

```python
from nova_act import NovaAct, ActError
from pydantic import BaseModel

# Always use context manager pattern
with NovaAct(starting_page="https://example.com") as nova:
    # Break into small, specific act() calls
    nova.act("specific atomic action")
    nova.act("another specific action")
```

### Critical Best Practices

1. **Use context managers** (`with NovaAct(...) as nova:`) for automatic cleanup
2. **Break tasks into small act() calls** - each call should do ONE specific thing
3. **Use Pydantic schemas** for all data extraction (never parse text manually)
4. **Use `BOOL_SCHEMA`** for yes/no questions
5. **Use `go_to_url()` not `page.goto()`** for reliability
6. **Handle sensitive data** with Playwright directly (`nova.page.keyboard.type(password)`)
7. **Include error handling** with try/except ActError
8. **Add descriptive comments** explaining workflow logic

### Data Extraction Pattern

```python
from pydantic import BaseModel

class ProductInfo(BaseModel):
    name: str
    price: float
    in_stock: bool

result = nova.act(
    "Extract the product name, price, and stock status",
    schema=ProductInfo.model_json_schema()
)

if result.matches_schema:
    product = ProductInfo.model_validate(result.parsed_response)
```

### Parallel Execution Pattern

```python
from concurrent.futures import ThreadPoolExecutor, as_completed

def scrape_site(url):
    with NovaAct(starting_page=url, headless=True) as nova:
        return nova.act("extract data")

with ThreadPoolExecutor(max_workers=5) as executor:
    futures = {executor.submit(scrape_site, url): url for url in urls}
    for future in as_completed(futures):
        result = future.result()
```

### Authentication Pattern

```python
import os

user_data_dir = "/tmp/browser-profile"
os.makedirs(user_data_dir, exist_ok=True)

# First run: authenticate
with NovaAct(
    starting_page="https://example.com",
    user_data_dir=user_data_dir,
    clone_user_data_dir=False  # Don't delete on close
) as nova:
    input("Log in, then press Enter...")

# Subsequent runs: reuse authentication
with NovaAct(
    starting_page="https://example.com",
    user_data_dir=user_data_dir,
    clone_user_data_dir=True  # Clone for parallel safety
) as nova:
    nova.act("navigate to dashboard")
```

## Common Prompting Anti-Patterns

### ❌ DON'T: Vague or conversational prompts
```python
nova.act("Let's see what's available")  # Too vague
nova.act("Find me a good deal")  # Too high-level
```

### ✅ DO: Specific, prescriptive instructions
```python
nova.act("Click the 'Sort by Price' dropdown and select 'Low to High'")
nova.act("Find the first product under $100 and click on it")
```

### ❌ DON'T: Try to do everything in one act() call
```python
nova.act("Search for laptops, filter by price under $1000, sort by rating, and add the best one to cart")
```

### ✅ DO: Break into multiple atomic steps
```python
nova.act("search for laptops")
nova.act("set price filter to under $1000")
nova.act("sort by customer rating")
nova.act("click on the first result")
nova.act("click add to cart")
```

## Security Requirements

1. **Never pass passwords to act()** - use `nova.page.keyboard.type(password)` instead
2. **Use getpass()** for password input: `password = getpass.getpass()`
3. **Be aware of screenshots** - Nova Act captures screenshots during execution
4. **Detect captchas** with BOOL_SCHEMA and pause for human intervention

## Key NovaAct Initialization Parameters

```python
NovaAct(
    starting_page="https://example.com",  # Required
    headless=False,                       # True for production
    quiet=False,                          # Suppress logs
    user_data_dir=None,                   # Browser profile path
    clone_user_data_dir=True,             # Clone profile (for parallel execution)
    logs_directory=None,                  # Where to store traces
    record_video=False,                   # Record session video
    go_to_url_timeout=30,                 # Page load timeout (seconds)
)
```

## Error Handling

```python
from nova_act import ActError, ActAgentError, ActClientError, ActServerError

try:
    result = nova.act("perform action")
except ActAgentError:
    # Retry with different prompt
    pass
except ActClientError:
    # Fix request and retry
    pass
except ActServerError:
    # Report to team
    pass
```

## Running Examples

```bash
# Install Nova Act SDK
pip install nova-act

# Install Chrome (recommended)
playwright install chrome

# Set API key (get from https://nova.amazon.com/act)
export NOVA_ACT_API_KEY="your_api_key"

# Run examples
python plugins/nova-act-skill/examples/01_price_comparison.py
python plugins/nova-act-skill/examples/02_form_filling.py
python plugins/nova-act-skill/examples/03_monitoring_alerts.py
```

## Known Limitations

- **US availability only**
- **English language only**
- Cannot interact with non-browser applications
- Not optimized for PDF actuation
- Unreliable with very high-level prompts (break into smaller steps)
- Screen size optimized for 864×1296 to 1536×2304 resolution
- No iPython support

## When Generating Scripts

1. Start by reading `plugins/nova-act-skill/SKILL.md` for complete API reference
2. Use examples in `plugins/nova-act-skill/examples/` as templates for similar use cases
3. Always include proper imports at the top
4. Add docstrings explaining what the script does
5. Include prerequisite comments (API key, installations)
6. Use descriptive variable names
7. Add error handling for production readiness
8. Consider whether headless mode is appropriate
9. Include result validation and output formatting
10. Save important data to files (JSON, CSV, etc.)

## Adding New Plugins

When adding new plugins to this marketplace:

1. Create a new directory under `plugins/`
2. Add a `.claude-plugin/plugin.json` manifest
3. Include all necessary documentation and code
4. Update `.claude-plugin/marketplace.json` to register the plugin
5. Update the root `README.md` to list the new plugin

## Resources

- Official Repo: https://github.com/aws/nova-act
- Documentation: https://nova.amazon.com/act
- Blog: https://labs.amazon.science/blog/nova-act
- Support: nova-act@amazon.com
