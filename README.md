# apresai Skills Marketplace

**Production-ready AI automation skills for Claude Code**

Transform complex browser workflows into simple Python scripts using natural language. Build web scrapers, automate forms, monitor websites, and more—all powered by Amazon Nova Act's AI browser automation.

---

## What Is This?

This marketplace provides **ready-to-use skills** that teach Claude Code how to generate production-quality automation scripts. Currently featuring the **Nova Act skill**, which enables Claude to create browser automation workflows using natural language commands.

### What Can You Build?

**E-commerce Automation**
- Compare prices across Amazon, Best Buy, Target (see it run in parallel!)
- Monitor products for price drops and stock availability
- Automate order tracking and status updates
- Extract product reviews and ratings at scale

**Form Automation**
- Auto-fill job applications with your resume data
- Submit surveys and feedback forms in bulk
- Create accounts across multiple platforms
- Handle multi-step registration workflows

**Web Scraping & Monitoring**
- Extract structured data from any website
- Monitor competitors' pricing and inventory
- Track real estate listings for new properties
- Get alerts when content changes on websites you care about

**Testing & QA**
- Automate user flow testing
- Validate forms and checkout processes
- Run regression tests across browsers
- Screenshot capture for visual testing

---

## Quick Start

### 1. Install the Marketplace

In Claude Code, add this marketplace:

```bash
/plugin marketplace add apresai/nova-act-skill
```

### 2. Get Your Nova Act API Key

1. Visit [nova.amazon.com/act](https://nova.amazon.com/act)
2. Sign in with your Amazon.com account (the one you shop with)
3. Generate your API key
4. Set it in your environment:

```bash
export NOVA_ACT_API_KEY="your_api_key_here"
```

### 3. Install Nova Act SDK

```bash
pip install nova-act
playwright install chrome
```

### 4. Ask Claude to Build Something!

Try these example prompts with Claude Code:

> *"Using the Nova Act skill, create a script that searches Amazon for wireless headphones under $200, extracts the top 5 results with prices and ratings, and saves them to a CSV file."*

> *"Build a Nova Act script that monitors a specific product page on Best Buy and sends me an alert when the price drops below $500."*

> *"Create a form-filling script that logs into my job portal and applies to positions matching my criteria."*

Claude will generate a complete, production-ready Python script using Nova Act best practices.

---

## Available Skills

### 🤖 nova-act-skill

**AI-Powered Browser Automation**

Generate production-ready Python scripts that control web browsers using natural language commands. Built on Amazon Nova Act, the AI-native browser automation SDK.

**What's Included:**
- Complete Nova Act API reference (20KB skill document)
- 3 production-ready example scripts with full source code
- Best practices guide and common patterns
- Security guidelines for handling credentials
- Quick start guide with troubleshooting

**Example Scripts:**

1. **Price Comparison** (`01_price_comparison.py`)
   - Parallel web scraping across Amazon, Best Buy, Target
   - Pydantic schemas for structured data extraction
   - Comparison analysis with savings calculation
   - JSON export of results

2. **Form Filling** (`02_form_filling.py`)
   - Persistent authentication with saved sessions
   - Captcha detection and human intervention
   - File upload handling
   - Screenshot verification

3. **Monitoring & Alerts** (`03_monitoring_alerts.py`)
   - Headless automation for scheduled tasks
   - Change detection algorithms
   - Alert triggering on price/stock changes
   - Historical data tracking

**Install:**
```bash
/plugin install nova-act-skill
```

**Documentation:** [nova-act-skill](./plugins/nova-act-skill/README.md)

---

## How It Works

### Traditional Approach
```python
# Complex, brittle code
from selenium import webdriver
driver = webdriver.Chrome()
driver.get("https://example.com")
search_box = driver.find_element(By.ID, "search")
search_box.send_keys("product")
submit = driver.find_element(By.CSS_SELECTOR, "button[type='submit']")
submit.click()
# Hope the selectors don't change!
```

### Nova Act Approach
```python
# Simple, natural language
from nova_act import NovaAct

with NovaAct(starting_page="https://example.com") as nova:
    nova.act("search for product")
    nova.act("click the first result")
    # AI figures out the selectors!
```

### The Claude Code + Nova Act Advantage

Just tell Claude what you want to automate, and it generates the complete script:

**Your Request:**
> "Create a script that finds the cheapest laptop under $1000 on Amazon"

**Claude Generates:**
```python
from nova_act import NovaAct
from pydantic import BaseModel

class Laptop(BaseModel):
    name: str
    price: float
    rating: float

with NovaAct(starting_page="https://amazon.com") as nova:
    nova.act("search for laptops")
    nova.act("set price filter to under $1000")
    nova.act("sort by price low to high")

    result = nova.act(
        "Extract name, price, and rating of the first laptop",
        schema=Laptop.model_json_schema()
    )

    if result.matches_schema:
        laptop = Laptop.model_validate(result.parsed_response)
        print(f"Best deal: {laptop.name} - ${laptop.price}")
```

---

## Why Use This Marketplace?

**For Individual Developers:**
- Skip the learning curve—Claude knows the best practices
- Get production-ready code, not examples that need fixing
- Save hours of debugging with proven patterns
- Built-in error handling and security considerations

**For Teams:**
- Standardize automation across your organization
- Reduce training time for new team members
- Leverage AI without requiring ML expertise
- Maintain consistent code quality

**For Researchers & Data Scientists:**
- Collect data from multiple sources in parallel
- No more fighting with Selenium or BeautifulSoup
- Focus on analysis, not web scraping infrastructure
- Reproducible data collection workflows

---

## Real-World Use Cases

### E-commerce Research
"I need to track prices for 50 products across 3 retailers daily."
- **Solution:** Nova Act script with parallel execution + cron job
- **Time saved:** Manual checking would take 2+ hours/day → 5 minutes automated

### Job Application Automation
"I'm applying to 100+ positions with similar requirements."
- **Solution:** Form-filling script with saved authentication
- **Time saved:** 30 minutes per application → 2 minutes automated

### Competitive Intelligence
"Monitor competitor websites for product launches and pricing changes."
- **Solution:** Headless monitoring script with email alerts
- **Time saved:** Continuous monitoring vs manual daily checks

### QA Testing
"Test our checkout flow across different scenarios and browsers."
- **Solution:** Automated testing with screenshot capture
- **Time saved:** 2 hours of manual testing → 10 minutes automated

---

## Key Features

### 🧠 AI-Native Automation
No CSS selectors. No XPath. Just describe what you want in plain English.

### 📊 Structured Data Extraction
Use Pydantic schemas to extract clean, typed data—no regex parsing nightmares.

### ⚡ Parallel Execution
Run multiple browser sessions concurrently. Compare prices across 10 retailers in the time it takes to check one.

### 🔒 Security-First
Built-in patterns for handling passwords, sessions, and sensitive data safely.

### 🎯 Production-Ready
Error handling, logging, retry logic, and monitoring built into generated code.

### 📚 Complete Documentation
20KB skill reference, working examples, troubleshooting guides, and best practices.

---

## System Requirements

- **Python:** 3.10 or higher
- **Operating Systems:** macOS, Ubuntu 22.04+, WSL2, Windows 10+
- **Location:** US-based (Nova Act is currently US-only)
- **Browser:** Chrome recommended (auto-installed via Playwright)
- **API Key:** Free tier available at [nova.amazon.com/act](https://nova.amazon.com/act)

---

## Installation

### Step 1: Add to Claude Code
```bash
/plugin marketplace add apresai/nova-act-skill
/plugin install nova-act-skill
```

### Step 2: Install Nova Act SDK
```bash
pip install nova-act
playwright install chrome
```

### Step 3: Set API Key
```bash
export NOVA_ACT_API_KEY="your_api_key_from_nova.amazon.com"
```

### Step 4: Test It Out
```bash
python plugins/nova-act-skill/examples/01_price_comparison.py
```

See the [Quick Start Guide](./plugins/nova-act-skill/QUICKSTART.md) for detailed setup instructions and troubleshooting.

---

## Documentation

- **[Nova Act Skill README](./plugins/nova-act-skill/README.md)** - Overview and usage guide
- **[Quick Start Guide](./plugins/nova-act-skill/QUICKSTART.md)** - 5-minute setup walkthrough
- **[Skill Reference](./plugins/nova-act-skill/SKILL.md)** - Complete API documentation (20KB)
- **[Package Overview](./plugins/nova-act-skill/OVERVIEW.md)** - Detailed contents and learning paths
- **[Example Scripts](./plugins/nova-act-skill/examples/)** - Three production-ready examples

---

## Example Gallery

### Price Comparison Script
Searches multiple retailers in parallel and finds the best deal:

```python
# Run searches concurrently
with ThreadPoolExecutor(max_workers=3) as executor:
    futures = {
        executor.submit(search_amazon, "headphones"): "Amazon",
        executor.submit(search_bestbuy, "headphones"): "Best Buy",
        executor.submit(search_target, "headphones"): "Target",
    }
```

**Output:**
```
PRICE COMPARISON RESULTS
========================================
1. Target
   Product: Sony WH-1000XM5
   Price: $349.99
   In Stock: Yes
   Rating: 4.8/5.0

Best Deal: Target at $349.99
Savings: $50.00 vs most expensive option
```

### Monitoring Script
Detects price changes and sends alerts:

```python
monitor = WebsiteMonitor(
    url="https://www.example.com/product",
    check_interval=3600,  # Check every hour
    alert_on_price_drop=True
)
monitor.run()
```

**Output:**
```
🔔 ALERT: Price dropped from $399.99 to $349.99!
📊 Monitoring session complete:
   - Total checks: 24
   - Changes detected: 2
   - Price alerts: 1
```

---

## Best Practices (Built Into Generated Code)

### ✅ Break Tasks Into Small Steps
Nova Act works best with atomic, specific commands:
```python
# Good
nova.act("click the search button")
nova.act("enter 'laptops' in the search box")
nova.act("click the first result")

# Not ideal
nova.act("search for laptops and click the first result")
```

### ✅ Use Schemas for Data
Always use Pydantic for structured extraction:
```python
class Product(BaseModel):
    name: str
    price: float
    in_stock: bool

result = nova.act("extract product info", schema=Product.model_json_schema())
```

### ✅ Handle Errors Gracefully
Production code includes proper error handling:
```python
from nova_act import ActError

try:
    with NovaAct(starting_page=url) as nova:
        nova.act("perform action")
except ActError as e:
    logger.error(f"Automation failed: {e}")
    # Retry or alert
```

### ✅ Secure Credential Handling
Never pass passwords to act() prompts:
```python
# Good - direct Playwright interaction
import getpass
password = getpass.getpass()
nova.page.keyboard.type(password)

# Bad - visible in screenshots
nova.act(f"enter password {password}")
```

---

## Limitations

- **Geographic:** US availability only
- **Language:** English language only
- **Scope:** Browser-based automation only (no desktop apps)
- **PDF:** Not optimized for PDF interaction
- **Complexity:** Very high-level prompts may be unreliable (break into steps)
- **Screen Size:** Optimized for 864×1296 to 1536×2304 resolution

---

## Support & Resources

**Nova Act Official:**
- Documentation: [nova.amazon.com/act](https://nova.amazon.com/act)
- GitHub: [github.com/aws/nova-act](https://github.com/aws/nova-act)
- Blog: [labs.amazon.science/blog/nova-act](https://labs.amazon.science/blog/nova-act)
- Email: nova-act@amazon.com

**This Marketplace:**
- Issues: [github.com/apresai/apresai-skills/issues](https://github.com/apresai/apresai-skills/issues)
- Maintained by: [apresai](https://github.com/apresai)

---

## Roadmap

**Coming Soon:**
- Additional example scripts (data collection, testing workflows)
- Video tutorials and walkthroughs
- Integration templates for common services (email, Slack, databases)
- More AI automation skills beyond browser control

**Future Plugins:**
- Computer vision skills for image processing
- Natural language processing for text analysis
- Data analysis and visualization skills

---

## Contributing

Want to contribute an example script, improve documentation, or add a new skill?

- Submit issues and pull requests on GitHub
- Share your automation scripts with the community
- Suggest new use cases and examples

*(Full contribution guidelines coming soon)*

---

## License

See individual plugin directories for licensing information. Nova Act SDK is subject to Amazon's licensing and acceptable use policies.

---

## Get Started Today

```bash
# 1. Add marketplace
/plugin marketplace add apresai/nova-act-skill

# 2. Install skill
/plugin install nova-act-skill

# 3. Ask Claude
"Using the Nova Act skill, create a script that..."
```

**Stop writing brittle web scrapers. Start describing what you want in plain English.**

---

**Last Updated:** November 2025
**Marketplace Version:** 1.0
**Featured Skill:** nova-act-skill v1.0
