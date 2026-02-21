---
name: nova-act-builder
description: Generate production-ready Amazon Nova Act Python scripts for browser automation using AI-powered SDK that breaks complex tasks into reliable atomic commands with natural language instructions
---

# Nova Act Script Builder

## Overview
This skill enables Claude to create production-ready Amazon Nova Act Python scripts for browser automation. Nova Act is a research preview SDK from Amazon AGI that combines AI with browser automation to create reliable, maintainable web workflows.

## What is Nova Act?

Amazon Nova Act is an AI model trained to perform actions within web browsers, accessible through the Nova Act SDK. Unlike traditional brittle automation scripts, Nova Act:
- Uses natural language commands combined with Python code
- Breaks complex workflows into smaller, reliable atomic commands
- Allows interleaving of Python code (tests, breakpoints, assertions, parallelization)
- Maintains high reliability (>90% on internal evals for common UI patterns)

**Key Philosophy**: Break tasks into multiple `act()` calls rather than one large end-to-end prompt. This increases reliability and maintainability.

## Prerequisites

- **Operating System**: MacOS Sierra+, Ubuntu 22.04+, WSL2 or Windows 10+
- **Python**: 3.10 or above
- **Language**: English only
- **Installation**: `pip install nova-act`
- **API Key**: Required from https://nova.amazon.com/act (US only)
- **Browser**: Works best with Google Chrome (can be installed via `playwright install chrome`)

## Core Nova Act Script Structure

### Basic Template

```python
from nova_act import NovaAct

# Set API key as environment variable first:
# export NOVA_ACT_API_KEY="your_api_key"

with NovaAct(starting_page="https://example.com") as nova:
    nova.act("search for coffee maker")
    nova.act("select the first result")
    nova.act("scroll down until you see 'add to cart' and click it")
```

### Script Components

**1. Imports**
```python
from nova_act import NovaAct
from nova_act import BOOL_SCHEMA, ActResult, ActError
from pydantic import BaseModel  # For structured data extraction
from concurrent.futures import ThreadPoolExecutor, as_completed  # For parallel execution
import getpass  # For sensitive data handling
```

**2. NovaAct Initialization Parameters**

```python
NovaAct(
    starting_page="https://example.com",  # Required: starting URL or file:// path
    headless=False,  # True for headless mode (production)
    quiet=False,  # True to suppress logs
    user_data_dir=None,  # Path to Chrome profile directory
    clone_user_data_dir=True,  # Whether to clone the user data dir
    nova_act_api_key=None,  # API key (if not set as env var)
    logs_directory=None,  # Where to store logs and traces
    record_video=False,  # Record video of session
    user_agent=None,  # Custom user agent string
    proxy=None,  # Proxy configuration dict
    go_to_url_timeout=30,  # Timeout for page loads in seconds
    state_guardrail=None,  # Callback function for URL filtering
)
```

**3. Context Manager Pattern** (Recommended)
```python
with NovaAct(starting_page="https://example.com") as nova:
    # Your automation code here
    pass
# Browser automatically closed
```

**4. Manual Start/Stop Pattern**
```python
nova = NovaAct(starting_page="https://example.com")
nova.start()
# Your automation code here
nova.stop()
```

## Prompting Best Practices

### ✅ DO: Be Prescriptive and Succinct

```python
# Good: Clear, specific instructions
nova.act("Click the hamburger menu icon, go to Order History, find my most recent order from India Palace and reorder it")

# Good: Break into smaller steps
nova.act("Navigate to the routes tab")
nova.act(f"Find the next departure time for the Orange Line from Government Center after {time}")
```

### ❌ DON'T: Use Vague or Conversational Prompts

```python
# Bad: Too vague
nova.act("Let's see what routes vta offers")

# Bad: Too high-level
nova.act("From my order history, find my most recent order from India Palace and reorder it")

# Bad: Entire workflow in one command
nova.act("book me a hotel that costs less than $100 with the highest star rating")
```

### ✅ DO: Break Large Tasks Into Smaller Acts

```python
# Good: Multiple smaller steps
nova.act(f"search for hotels in Houston between {startdate} and {enddate}")
nova.act("sort by avg customer review")
nova.act("hit book on the first hotel that is $100 or less")
nova.act(f"fill in my name, address, and DOB according to {blob}")
```

## Data Extraction with Pydantic Schemas

### Structured Data Extraction

```python
from pydantic import BaseModel
from nova_act import NovaAct, ActResult

class Book(BaseModel):
    title: str
    author: str

class BookList(BaseModel):
    books: list[Book]

def get_books(year: int) -> BookList | None:
    with NovaAct(
        starting_page=f"https://en.wikipedia.org/wiki/List_of_The_New_York_Times_number-one_books_of_{year}#Fiction"
    ) as nova:
        result = nova.act(
            "Return the books in the Fiction list",
            schema=BookList.model_json_schema()  # Pass schema
        )
        
        if not result.matches_schema:
            return None
        
        # Parse the JSON into the pydantic model
        book_list = BookList.model_validate(result.parsed_response)
        return book_list
```

### Boolean Responses

```python
from nova_act import NovaAct, BOOL_SCHEMA

with NovaAct(starting_page="https://example.com") as nova:
    result = nova.act("Am I logged in?", schema=BOOL_SCHEMA)
    
    if result.matches_schema and result.parsed_response:
        print("You are logged in")
    else:
        print("You are not logged in")
```

### ActResult Object

```python
class ActResult:
    response: str | None  # Raw response text
    parsed_response: Union[Dict, List, str, int, float, bool] | None  # Parsed JSON
    valid_json: bool | None  # Whether response is valid JSON
    matches_schema: bool | None  # Whether response matches provided schema
    metadata: ActMetadata  # Execution metadata
```

## Parallel Execution

```python
from concurrent.futures import ThreadPoolExecutor, as_completed
from nova_act import ActError, NovaAct

all_books = []

# Set max workers to the max number of active browser sessions
with ThreadPoolExecutor(max_workers=10) as executor:
    # Submit tasks in parallel
    future_to_books = {
        executor.submit(get_books, year): year 
        for year in range(2010, 2025)
    }
    
    # Collect results
    for future in as_completed(future_to_books.keys()):
        try:
            year = future_to_books[future]
            book_list = future.result()
            if book_list is not None:
                all_books.extend(book_list.books)
        except ActError as exc:
            print(f"Skipping year {year} due to error: {exc}")

print(f"Found {len(all_books)} books")
```

## Authentication and Browser State

### Persisting Browser Sessions

```python
import os
from nova_act import NovaAct

user_data_dir = "/tmp/my-browser-profile"
os.makedirs(user_data_dir, exist_ok=True)

# First run: Authenticate
with NovaAct(
    starting_page="https://example.com",
    user_data_dir=user_data_dir,
    clone_user_data_dir=False  # Don't clone or delete the directory
) as nova:
    input("Log into your websites, then press enter...")
    # Session state is saved

# Subsequent runs: Use saved authentication
with NovaAct(
    starting_page="https://example.com",
    user_data_dir=user_data_dir,
    clone_user_data_dir=True  # Clone for parallel execution if needed
) as nova:
    # Already logged in
    nova.act("navigate to my account")
```

### Convenience Script
```bash
python -m nova_act.samples.setup_chrome_user_data_dir
```

## Handling Sensitive Data

### Password Entry (Secure)

```python
import getpass
from nova_act import NovaAct

with NovaAct(starting_page="https://example.com/login") as nova:
    # Enter username normally
    nova.act("enter username janedoe and click on the password field")
    
    # Use Playwright directly for sensitive data
    password = getpass.getpass()
    nova.page.keyboard.type(password)
    
    # Continue with login
    nova.act("sign in")
```

**Important**: Screenshots taken during execution will capture any visible sensitive information.

## Common Patterns

### Search on Website

```python
nova.go_to_url("https://example.com")
nova.act("search for cats. type enter to initiate the search.")
```

### Captcha Handling

```python
from nova_act import BOOL_SCHEMA

result = nova.act("Is there a captcha on the screen?", schema=BOOL_SCHEMA)
if result.matches_schema and result.parsed_response:
    input("Please solve the captcha and hit return when done")
```

### File Downloads

```python
# Download via button
with nova.page.expect_download() as download_info:
    nova.act("click on the download button")

# Save the file
download_info.value.save_as("my_downloaded_file")

# Download current page (PDF)
response = nova.page.request.get(nova.page.url)
with open("downloaded.pdf", "wb") as f:
    f.write(response.body())
```

### File Uploads

```python
# Upload file
nova.page.set_input_files('input[type="file"]', "path/to/upload.pdf")

# Wait for upload completion
nova.act("wait for the upload spinner to finish")
```

### Date Picking

```python
# Use absolute dates for best results
nova.act("select dates march 23 to march 28")
```

### Navigation

```python
# Prefer go_to_url over page.goto() for reliability
nova.go_to_url("https://example.com")

# Playwright page.goto() has 30s timeout and may be unreliable
```

### URL Guardrails

```python
from nova_act import NovaAct, GuardrailDecision, GuardrailInputState

def url_guardrail(state: GuardrailInputState) -> GuardrailDecision:
    if "blocked-domain.com" in state.browser_url:
        return GuardrailDecision.BLOCK
    return GuardrailDecision.PASS

with NovaAct(
    starting_page="https://example.com",
    state_guardrail=url_guardrail
) as nova:
    nova.act("Navigate to the homepage")
```

## Error Handling

### Error Types

```python
from nova_act import (
    ActError,  # Base error class
    ActAgentError,  # Agent failed to complete task - can retry
    ActExecutionError,  # Local execution error
    ActClientError,  # Invalid request - can retry with different request
    ActServerError,  # Server error - report to team
)

try:
    result = nova.act("click the button")
except ActAgentError as e:
    # Retry with different prompt
    print(f"Agent error: {e}")
except ActClientError as e:
    # Fix request and retry
    print(f"Client error: {e}")
except ActServerError as e:
    # Report to team
    print(f"Server error: {e}")
```

## Act Method Parameters

```python
result = nova.act(
    prompt="search for coffee maker",  # Required: natural language instruction
    max_steps=30,  # Max browser actuations before timeout
    timeout=None,  # Timeout in seconds (prefer max_steps)
    observation_delay_ms=None,  # Delay before taking screenshot
    schema=None,  # Pydantic schema for structured responses
)
```

## Logging and Debugging

### Log Levels

```bash
# Set log level via environment variable
export NOVA_ACT_LOG_LEVEL=20  # INFO level (default)
# 10 = DEBUG, 20 = INFO, 30 = WARNING, 40 = ERROR
```

### Trace Output

After each `act()` call, Nova Act outputs an HTML trace file:
```
** View your act run here: /tmp/tmpk7_23qte_nova_act_logs/15d2a29f.../act_844b076b...html
```

### Video Recording

```python
with NovaAct(
    starting_page="https://example.com",
    logs_directory="/path/to/logs",
    record_video=True
) as nova:
    # Session will be recorded
    pass
```

### Viewing Headless Sessions

```bash
# Set remote debugging port
export NOVA_ACT_BROWSER_ARGS="--remote-debugging-port=9222"
```

Then visit `http://localhost:9222/json` and use the `devtoolsFrontendUrl` to view the session.

## Advanced Features

### Proxy Configuration

```python
proxy_config = {
    "server": "http://proxy.example.com:8080",
    "username": "myusername",  # Optional
    "password": "mypassword"   # Optional
}

with NovaAct(starting_page="https://example.com", proxy=proxy_config) as nova:
    pass
```

### Custom User Agent

```python
with NovaAct(
    starting_page="https://example.com",
    user_agent="MyBot/1.0"
) as nova:
    pass
```

### Direct Playwright Access

```python
# Access Playwright Page object directly
screenshot_bytes = nova.page.screenshot()
dom_string = nova.page.content()
nova.page.keyboard.type("hello")
current_url = nova.page.url
```

### Using Default Chrome Browser (MacOS Only)

```python
from nova_act import NovaAct, rsync_from_default_user_data

working_user_data_dir = "/Users/$USER/chrome-work-dir"
rsync_from_default_user_data(working_user_data_dir)

nova = NovaAct(
    use_default_chrome_browser=True,
    clone_user_data_dir=False,
    user_data_dir=working_user_data_dir,
    starting_page="https://example.com"
)
nova.start()
```

### S3 Storage Integration

```python
import boto3
from nova_act import NovaAct
from nova_act.util.s3_writer import S3Writer

boto_session = boto3.Session()

s3_writer = S3Writer(
    boto_session=boto_session,
    s3_bucket_name="my-bucket",
    s3_prefix="my-prefix/",
    metadata={"Project": "MyProject"}
)

with NovaAct(
    starting_page="https://example.com",
    boto_session=boto_session,
    stop_hooks=[s3_writer]
) as nova:
    nova.act("perform task")
# Session data automatically uploaded to S3
```

## Integration with Amazon Bedrock AgentCore

Nova Act can integrate with Amazon Bedrock AgentCore Browser Tool for production-scale browser automation:

```python
from playwright.async_api import async_playwright
from bedrock_agentcore.tools.browser_client import browser_session

async def run(playwright):
    with browser_session('us-west-2') as client:
        ws_url, headers = client.generate_ws_headers()
        browser = await playwright.chromium.connect_over_cdp(ws_url, headers=headers)
        # Use with Nova Act...
```

## Known Limitations

1. **Cannot interact with non-browser applications**
2. **Unreliable with very high-level prompts** - break into smaller steps
3. **Cannot interact with elements behind mouseover**
4. **Cannot interact with browser modals** (location requests, etc.)
5. **Not optimized for PDF actuation**
6. **Screen size constraints**: Optimized for 864×1296 to 1536×2304 resolution
7. **No iPython support** - use standard Python shell
8. **US availability only**
9. **English language only**

## Example Complete Scripts

### Simple Shopping Flow

```python
from nova_act import NovaAct

with NovaAct(starting_page="https://www.amazon.com") as nova:
    nova.act("search for wireless headphones")
    nova.act("sort by customer rating")
    nova.act("click on the first product under $100")
    nova.act("scroll down until you see 'add to cart' and click it")
```

### Data Extraction with Schema

```python
from pydantic import BaseModel
from nova_act import NovaAct

class ProductInfo(BaseModel):
    name: str
    price: float
    rating: float
    in_stock: bool

with NovaAct(starting_page="https://example.com/product/123") as nova:
    result = nova.act(
        "Extract the product name, price, rating, and stock status",
        schema=ProductInfo.model_json_schema()
    )
    
    if result.matches_schema:
        product = ProductInfo.model_validate(result.parsed_response)
        print(f"Found {product.name} for ${product.price}")
```

### Authenticated Session with Parallel Execution

```python
import os
from concurrent.futures import ThreadPoolExecutor
from nova_act import NovaAct, ActError

def scrape_account_data(account_id: str, user_data_dir: str):
    """Scrape data for a single account"""
    with NovaAct(
        starting_page="https://example.com/dashboard",
        user_data_dir=user_data_dir,
        clone_user_data_dir=True,  # Clone for parallel safety
        headless=True
    ) as nova:
        nova.act(f"navigate to account {account_id}")
        result = nova.act("extract all transactions")
        return result.parsed_response

# Setup authentication once
user_data_dir = "/tmp/authenticated-session"
os.makedirs(user_data_dir, exist_ok=True)

with NovaAct(
    starting_page="https://example.com/login",
    user_data_dir=user_data_dir,
    clone_user_data_dir=False
) as nova:
    input("Please log in, then press Enter...")

# Now run parallel sessions using the authenticated state
account_ids = ["123", "456", "789"]
results = []

with ThreadPoolExecutor(max_workers=3) as executor:
    futures = {
        executor.submit(scrape_account_data, acc_id, user_data_dir): acc_id
        for acc_id in account_ids
    }
    
    for future in futures:
        try:
            data = future.result()
            results.append(data)
        except ActError as e:
            print(f"Error: {e}")

print(f"Collected {len(results)} results")
```

## Script Generation Guidelines

When generating Nova Act scripts, Claude should:

1. **Always use the context manager pattern** (`with NovaAct(...) as nova:`)
2. **Break complex tasks into multiple `act()` calls** rather than one large prompt
3. **Use Pydantic schemas for data extraction** rather than parsing text
4. **Include proper error handling** with try/except blocks
5. **Use descriptive, prescriptive prompts** in act() calls
6. **Add comments** explaining the workflow logic
7. **Consider authentication needs** and whether to persist browser state
8. **Use `go_to_url()` instead of `page.goto()`** for reliability
9. **Handle sensitive data securely** using Playwright directly
10. **Include appropriate imports** at the top of the script
11. **Use `BOOL_SCHEMA`** for yes/no questions
12. **Consider parallel execution** for scalability when appropriate
13. **Add delays or wait conditions** where UI animations might interfere
14. **Include trace/log directory** for debugging purposes

## Script Template

```python
#!/usr/bin/env python3
"""
Nova Act Script: [Brief description of what this script does]

Prerequisites:
- Nova Act SDK installed: pip install nova-act
- API key set: export NOVA_ACT_API_KEY="your_key"
- [Any other prerequisites]
"""

from nova_act import NovaAct, BOOL_SCHEMA, ActError
from pydantic import BaseModel
import os

# Define data models if extracting structured data
class MyDataModel(BaseModel):
    field1: str
    field2: int

def main():
    """Main script execution"""
    
    # Configuration
    starting_url = "https://example.com"
    headless_mode = False  # Set to True for production
    
    try:
        with NovaAct(
            starting_page=starting_url,
            headless=headless_mode,
            logs_directory="./nova_act_logs"
        ) as nova:
            # Step 1: [Description]
            nova.act("specific action to perform")
            
            # Step 2: [Description]
            result = nova.act(
                "another specific action",
                schema=MyDataModel.model_json_schema()
            )
            
            # Process results
            if result.matches_schema:
                data = MyDataModel.model_validate(result.parsed_response)
                print(f"Success: {data}")
            else:
                print("Failed to extract data")
                
    except ActError as e:
        print(f"Nova Act error: {e}")
        return 1
    
    return 0

if __name__ == "__main__":
    exit(main())
```

## Common Use Cases

1. **E-commerce automation**: Product search, comparison, cart management
2. **Form filling**: Applications, surveys, data entry
3. **Web scraping**: Data extraction with structured schemas
4. **Testing**: Automated QA workflows for web applications
5. **Research**: Gathering data from multiple sources in parallel
6. **Account management**: Bulk operations across multiple accounts
7. **Monitoring**: Regular checks of website status or content
8. **Data migration**: Extracting data from legacy systems

## Resources

- **Official Repository**: https://github.com/aws/nova-act
- **Documentation**: https://nova.amazon.com/act
- **Blog Post**: https://labs.amazon.science/blog/nova-act
- **IDE Extension**: https://github.com/aws/nova-act-extension
- **Bug Reports**: nova-act@amazon.com
- **AgentCore Integration**: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/browser-tool.html

## Notes

- Nova Act is a **research preview** - expect limitations and changes
- **US availability only** at this time
- First run may take 1-2 minutes to install Playwright modules
- Always monitor Nova Act for production use
- Follow the Acceptable Use Policy
- Screenshots and prompts are collected to improve the service
