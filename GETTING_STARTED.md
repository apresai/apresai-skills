# Getting Started with apresai Skills Marketplace

**From zero to your first automation script in 10 minutes**

---

## What You'll Build

By the end of this guide, you'll have:
- A working Nova Act installation
- Your first AI-powered web automation script running
- The ability to ask Claude Code to generate custom automation scripts for any task

---

## Prerequisites

Before starting, make sure you have:

- [ ] **Python 3.10+** installed (`python --version`)
- [ ] **Claude Code** set up and working
- [ ] **Amazon.com account** (not AWS—your regular shopping account)
- [ ] **US-based location** (Nova Act is currently US-only)
- [ ] **10 minutes** of free time

---

## Step-by-Step Setup

### 1. Get Your Nova Act API Key (2 minutes)

1. Open your browser and go to: **[nova.amazon.com/act](https://nova.amazon.com/act)**
2. Click **"Sign In"** and use your Amazon.com credentials (the account you use for shopping)
3. Once logged in, click **"Generate API Key"**
4. **Copy the API key** to your clipboard (you'll need it in step 3)

> **Note:** If you're placed on a waitlist, you'll receive an email when access is granted. Most users get immediate access.

---

### 2. Add the Marketplace to Claude Code (1 minute)

Open Claude Code and run:

```bash
/plugin marketplace add apresai/nova-act-skill
```

Then browse available plugins:

```bash
/plugin
```

Install the Nova Act skill:

```bash
/plugin install nova-act-skill
```

---

### 3. Set Up Your Environment (3 minutes)

**Install the Nova Act SDK:**

```bash
pip install nova-act
```

**Install Chrome browser support:**

```bash
playwright install chrome
```

**Set your API key as an environment variable:**

```bash
# On Mac/Linux:
export NOVA_ACT_API_KEY="paste_your_api_key_here"

# To make it permanent, add to ~/.bashrc or ~/.zshrc:
echo 'export NOVA_ACT_API_KEY="your_api_key"' >> ~/.bashrc
source ~/.bashrc
```

**On Windows (PowerShell):**

```powershell
$env:NOVA_ACT_API_KEY="paste_your_api_key_here"

# To make it permanent:
[System.Environment]::SetEnvironmentVariable('NOVA_ACT_API_KEY', 'your_api_key', 'User')
```

---

### 4. Test Your Setup (2 minutes)

Create a test file called `test_nova.py`:

```python
from nova_act import NovaAct

print("Testing Nova Act installation...")

with NovaAct(starting_page="https://www.google.com") as nova:
    nova.act("search for python programming")
    print(f"\nSuccess! Current page: {nova.page.title()}")

print("✓ Nova Act is working perfectly!")
```

Run it:

```bash
python test_nova.py
```

**What to expect:**
- A Chrome browser window will open (you'll see it!)
- Nova Act will navigate to Google
- It will search for "python programming"
- You'll see the result in your terminal

> **First run note:** The first execution may take 1-2 minutes to download browser components. Subsequent runs are much faster!

---

### 5. Try a Production Example (2 minutes)

Run one of the included example scripts:

```bash
# Price comparison across multiple retailers
python plugins/nova-act-skill/examples/01_price_comparison.py
```

**What this does:**
- Searches for Sony WH-1000XM5 headphones on Amazon, Best Buy, and Target
- Runs searches in parallel (all at once!)
- Extracts prices, ratings, and availability
- Compares results and shows you the best deal
- Saves results to `price_comparison.json`

**Expected output:**
```
Searching for 'Sony WH-1000XM5 headphones' across multiple retailers...
============================================================
✓ Amazon: Found product
✓ Best Buy: Found product
✓ Target: Found product

============================================================
PRICE COMPARISON RESULTS
============================================================

1. Target
   Product: Sony WH-1000XM5 Wireless Headphones
   Price: $349.99
   In Stock: Yes
   Rating: 4.8/5.0

Best Deal: Target at $349.99
Savings: $50.00 vs most expensive option
```

---

## Your First Custom Script

Now that everything is working, let's have Claude generate a custom script for you.

### Example Prompt 1: Amazon Product Search

In Claude Code, say:

> *"Using the Nova Act skill, create a script that searches Amazon for wireless keyboards under $50, extracts the top 3 results with their prices and ratings, and saves them to a CSV file."*

Claude will generate a complete, production-ready script with:
- Proper imports and error handling
- Pydantic schemas for data extraction
- CSV export functionality
- Comments explaining each step

### Example Prompt 2: Website Monitoring

Try this prompt:

> *"Using the Nova Act skill, create a monitoring script that checks if a specific product on Best Buy is in stock, and prints an alert if the status changes."*

### Example Prompt 3: Form Automation

Or this one:

> *"Build a Nova Act script that fills out a contact form with my information: name, email, and message."*

---

## Common Use Cases to Try Next

Once you're comfortable with the basics, explore these common automation patterns:

### 🛒 E-commerce
- Track prices for items you want to buy
- Monitor stock availability for hard-to-find products
- Compare prices across multiple retailers
- Extract product reviews for analysis

### 📝 Forms & Data Entry
- Auto-fill job applications
- Submit surveys and feedback forms
- Create accounts on multiple platforms
- Upload and submit documents

### 📊 Data Collection
- Scrape competitor pricing
- Collect real estate listings
- Extract news articles or blog posts
- Gather research data from public websites

### 🔍 Monitoring
- Check website availability
- Detect content changes
- Monitor for new listings
- Track competitor updates

---

## Understanding the Workflow

Here's how Claude Code + Nova Act works:

```
You describe what you want
         ↓
Claude reads the Nova Act skill
         ↓
Claude generates production-ready Python code
         ↓
You run the script
         ↓
Nova Act controls the browser using AI
         ↓
Data extracted and saved
```

**The magic:** You never write CSS selectors, XPath, or fragile element IDs. Just describe what you want in plain English!

---

## Best Practices for Prompting Claude

### ✅ Good Prompts

**Specific and detailed:**
> "Using the Nova Act skill, create a script that searches Etsy for handmade mugs under $30, extracts the first 5 results with names, prices, and seller ratings, then saves to CSV."

**Mentions the skill:**
> "Using the Nova Act skill, build a monitoring script..."

**Clear requirements:**
> "Create a Nova Act script that logs into example.com (using saved authentication), navigates to the dashboard, and takes a screenshot."

### ❌ Prompts to Avoid

**Too vague:**
> "Make me a web scraper"

**Missing context:**
> "Extract product data from websites"

**Unrealistic scope:**
> "Build a script that automatically buys items when they go on sale"

---

## Troubleshooting

### Issue: "API key not found"

**Solution:**
```bash
# Check if it's set
echo $NOVA_ACT_API_KEY

# If empty, set it again
export NOVA_ACT_API_KEY="your_key"
```

### Issue: "Chrome/Playwright not found"

**Solution:**
```bash
playwright install chrome
```

### Issue: Script fails on a website

**Possible causes:**
1. **Captcha detected** - Add user intervention in your script
2. **Prompt too vague** - Break into smaller, specific steps
3. **Website changed** - Update the act() commands

**Solution pattern:**
```python
from nova_act import BOOL_SCHEMA

# Check for captcha
result = nova.act("Is there a captcha on the page?", schema=BOOL_SCHEMA)
if result.parsed_response:
    input("Please solve the captcha, then press Enter...")
```

### Issue: First run is very slow

**This is normal!** The first time you run Nova Act:
- Playwright downloads browser binaries (~200MB)
- This takes 1-2 minutes
- Subsequent runs are much faster (seconds)

---

## Next Steps

### 1. Explore the Examples

All three example scripts demonstrate different patterns:

```bash
# Price comparison (parallel execution)
python plugins/nova-act-skill/examples/01_price_comparison.py

# Form filling (authentication, captchas, uploads)
python plugins/nova-act-skill/examples/02_form_filling.py

# Monitoring (headless mode, change detection)
python plugins/nova-act-skill/examples/03_monitoring_alerts.py
```

### 2. Read the Documentation

- **[QUICKSTART.md](./plugins/nova-act-skill/QUICKSTART.md)** - 5-minute quick reference
- **[README.md](./plugins/nova-act-skill/README.md)** - Complete skill overview
- **[SKILL.md](./plugins/nova-act-skill/SKILL.md)** - Full API reference (20KB)

### 3. Build Your Own Automation

Think about repetitive tasks in your workflow:
- What websites do you check daily?
- What forms do you fill out regularly?
- What data do you collect manually?

Ask Claude to automate them!

### 4. Join the Community

- Share your scripts and use cases
- Report issues or suggest improvements
- Contribute new examples

---

## Quick Reference Commands

```bash
# Install marketplace
/plugin marketplace add apresai/nova-act-skill

# Install skill
/plugin install nova-act-skill

# Install SDK
pip install nova-act
playwright install chrome

# Set API key
export NOVA_ACT_API_KEY="your_key"

# Run test
python test_nova.py

# Run examples
python plugins/nova-act-skill/examples/01_price_comparison.py
```

---

## Example Script Templates

### Template 1: Basic Scraping

```python
from nova_act import NovaAct
from pydantic import BaseModel

class Data(BaseModel):
    field1: str
    field2: float

with NovaAct(starting_page="https://example.com") as nova:
    nova.act("navigate to the data page")

    result = nova.act(
        "Extract field1 and field2",
        schema=Data.model_json_schema()
    )

    if result.matches_schema:
        data = Data.model_validate(result.parsed_response)
        print(f"Extracted: {data}")
```

### Template 2: Monitoring

```python
from nova_act import NovaAct
import time

def check_status():
    with NovaAct(starting_page="https://example.com", headless=True) as nova:
        result = nova.act("Is the item in stock?", schema=BOOL_SCHEMA)
        return result.parsed_response

while True:
    if check_status():
        print("🔔 Item is in stock!")
        break
    time.sleep(300)  # Check every 5 minutes
```

### Template 3: Parallel Scraping

```python
from nova_act import NovaAct
from concurrent.futures import ThreadPoolExecutor

def scrape_url(url):
    with NovaAct(starting_page=url, headless=True) as nova:
        # Your scraping logic
        return result

urls = ["url1", "url2", "url3"]

with ThreadPoolExecutor(max_workers=3) as executor:
    results = list(executor.map(scrape_url, urls))
```

---

## Getting Help

**For Nova Act SDK issues:**
- Email: nova-act@amazon.com
- GitHub: [github.com/aws/nova-act/issues](https://github.com/aws/nova-act/issues)

**For this marketplace:**
- GitHub Issues: [github.com/apresai/apresai-skills/issues](https://github.com/apresai/apresai-skills/issues)

**For Claude Code:**
- Documentation: [claude.ai/code](https://claude.ai/code)

---

## You're Ready!

You now have everything you need to:
- ✅ Generate custom automation scripts with Claude
- ✅ Run production-ready examples
- ✅ Build your own workflows
- ✅ Extract data from any website
- ✅ Monitor sites for changes
- ✅ Automate repetitive tasks

**Start building something amazing!** 🚀

---

**Questions?** Open an issue or check the documentation linked above.

**Want to share what you built?** We'd love to see it—open a discussion on GitHub!
