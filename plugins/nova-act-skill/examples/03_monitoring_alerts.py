#!/usr/bin/env python3
"""
Nova Act Example: Website Monitoring and Alerts

This script demonstrates:
- Regular website monitoring
- Data extraction and comparison
- Alert triggering based on changes
- Logging and reporting

Use case: Monitor product availability, price changes, or website status

Prerequisites:
- Nova Act SDK: pip install nova-act
- API key: export NOVA_ACT_API_KEY="your_key"
"""

from nova_act import NovaAct, BOOL_SCHEMA, ActError
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
import json
import time
import os


class MonitoringResult(BaseModel):
    """Data model for monitoring check results"""
    timestamp: str
    url: str
    status: str  # 'success', 'error', 'changed'
    data: dict
    changes: Optional[List[str]] = None
    error_message: Optional[str] = None


class ProductMonitor(BaseModel):
    """Product information for monitoring"""
    name: str
    price: float
    in_stock: bool
    last_checked: str


class WebsiteMonitor:
    """Monitor websites for changes and send alerts"""
    
    def __init__(self, config_file: str = "monitor_config.json"):
        self.config_file = config_file
        self.results_file = "monitoring_results.json"
        self.previous_state = self.load_previous_state()
    
    def load_previous_state(self) -> dict:
        """Load previous monitoring state from file"""
        if os.path.exists(self.results_file):
            with open(self.results_file, 'r') as f:
                data = json.load(f)
                # Return the last result for each URL
                return {r['url']: r for r in data[-10:]}  # Keep last 10
        return {}
    
    def save_result(self, result: MonitoringResult):
        """Save monitoring result to file"""
        results = []
        if os.path.exists(self.results_file):
            with open(self.results_file, 'r') as f:
                results = json.load(f)
        
        results.append(result.model_dump())
        
        with open(self.results_file, 'w') as f:
            json.dump(results, f, indent=2)
    
    def check_product_page(
        self,
        url: str,
        product_name: str
    ) -> Optional[ProductMonitor]:
        """
        Check a product page and extract current information.
        
        Args:
            url: Product page URL
            product_name: Expected product name
        
        Returns:
            ProductMonitor object with current data, or None on error
        """
        try:
            with NovaAct(
                starting_page=url,
                headless=True,
                logs_directory="./logs/monitoring"
            ) as nova:
                # Check if page loaded successfully
                result = nova.act(
                    "Is the page showing an error or 'page not found'?",
                    schema=BOOL_SCHEMA
                )
                
                if result.matches_schema and result.parsed_response:
                    print(f"⚠ Page error detected for {url}")
                    return None
                
                # Extract product information
                result = nova.act(
                    "Extract the product name, current price (as a number), "
                    "and whether it's in stock (true/false)",
                    schema=ProductMonitor.model_json_schema()
                )
                
                if result.matches_schema:
                    product = ProductMonitor.model_validate(result.parsed_response)
                    product.last_checked = datetime.now().isoformat()
                    return product
                else:
                    print(f"⚠ Could not extract data from {url}")
                    return None
                    
        except ActError as e:
            print(f"Error checking {url}: {e}")
            return None
    
    def detect_changes(
        self,
        url: str,
        current: ProductMonitor,
        previous: Optional[dict]
    ) -> List[str]:
        """
        Detect changes between current and previous states.
        
        Returns:
            List of change descriptions
        """
        if not previous or 'data' not in previous:
            return ["First time monitoring this product"]
        
        changes = []
        prev_data = previous['data']
        
        # Check price change
        if prev_data.get('price') != current.price:
            old_price = prev_data.get('price', 0)
            diff = current.price - old_price
            direction = "increased" if diff > 0 else "decreased"
            changes.append(
                f"Price {direction} from ${old_price:.2f} to ${current.price:.2f} "
                f"(${abs(diff):.2f})"
            )
        
        # Check stock status change
        if prev_data.get('in_stock') != current.in_stock:
            status = "IN STOCK" if current.in_stock else "OUT OF STOCK"
            changes.append(f"Stock status changed to: {status}")
        
        # Check name change (might indicate wrong product)
        if prev_data.get('name') != current.name:
            changes.append(
                f"Product name changed from '{prev_data.get('name')}' "
                f"to '{current.name}'"
            )
        
        return changes
    
    def send_alert(self, changes: List[str], product: ProductMonitor, url: str):
        """
        Send alert about detected changes.
        In production, this would integrate with email, SMS, Slack, etc.
        """
        print("\n" + "="*60)
        print("🔔 ALERT: Changes Detected!")
        print("="*60)
        print(f"Product: {product.name}")
        print(f"URL: {url}")
        print(f"Time: {product.last_checked}")
        print("\nChanges:")
        for change in changes:
            print(f"  • {change}")
        print("="*60 + "\n")
        
        # In production, add integrations:
        # - Send email via SES
        # - Send SMS via SNS
        # - Post to Slack webhook
        # - Write to CloudWatch
    
    def monitor_products(self, urls: List[str]):
        """
        Monitor a list of product URLs and detect changes.
        
        Args:
            urls: List of product page URLs to monitor
        """
        print(f"Starting monitoring check at {datetime.now()}")
        print(f"Monitoring {len(urls)} product(s)...\n")
        
        for url in urls:
            print(f"Checking: {url}")
            
            # Extract product name from URL for reference
            product_name = url.split('/')[-1].replace('-', ' ').title()
            
            # Check current state
            current = self.check_product_page(url, product_name)
            
            if current:
                # Get previous state
                previous = self.previous_state.get(url)
                
                # Detect changes
                changes = self.detect_changes(url, current, previous)
                
                # Create result
                result = MonitoringResult(
                    timestamp=current.last_checked,
                    url=url,
                    status='changed' if changes and len(changes) > 1 else 'success',
                    data=current.model_dump(),
                    changes=changes if changes else None
                )
                
                # Send alert if significant changes detected
                if len(changes) > 1:  # More than just "first time monitoring"
                    self.send_alert(changes, current, url)
                else:
                    print(f"  ✓ No changes detected")
                
                # Save result
                self.save_result(result)
                
                # Update previous state
                self.previous_state[url] = result.model_dump()
                
                # Display current status
                print(f"  Price: ${current.price:.2f}")
                print(f"  Stock: {'In Stock' if current.in_stock else 'Out of Stock'}")
            else:
                # Error occurred
                result = MonitoringResult(
                    timestamp=datetime.now().isoformat(),
                    url=url,
                    status='error',
                    data={},
                    error_message="Failed to extract product data"
                )
                self.save_result(result)
                print(f"  ✗ Error checking product")
            
            print()
    
    def generate_report(self) -> str:
        """Generate a summary report of monitoring results"""
        if not os.path.exists(self.results_file):
            return "No monitoring data available"
        
        with open(self.results_file, 'r') as f:
            results = json.load(f)
        
        report = []
        report.append("="*60)
        report.append("MONITORING REPORT")
        report.append("="*60)
        report.append(f"Total checks: {len(results)}")
        
        # Group by URL
        urls = set(r['url'] for r in results)
        report.append(f"Products monitored: {len(urls)}")
        
        # Count statuses
        successes = sum(1 for r in results if r['status'] == 'success')
        changes = sum(1 for r in results if r['status'] == 'changed')
        errors = sum(1 for r in results if r['status'] == 'error')
        
        report.append(f"\nStatus breakdown:")
        report.append(f"  ✓ Successful checks: {successes}")
        report.append(f"  🔔 Changes detected: {changes}")
        report.append(f"  ✗ Errors: {errors}")
        
        # Recent changes
        recent_changes = [r for r in results[-20:] if r.get('changes')]
        if recent_changes:
            report.append(f"\nRecent changes ({len(recent_changes)}):")
            for r in recent_changes[-5:]:  # Show last 5
                report.append(f"\n  {r['timestamp']}")
                report.append(f"  URL: {r['url']}")
                for change in r['changes'][:3]:  # Show first 3 changes
                    report.append(f"    • {change}")
        
        report.append("\n" + "="*60)
        
        return "\n".join(report)


def scheduled_monitoring(urls: List[str], interval_minutes: int = 60, max_runs: int = 24):
    """
    Run monitoring on a schedule.
    
    Args:
        urls: List of URLs to monitor
        interval_minutes: Minutes between checks
        max_runs: Maximum number of monitoring runs
    """
    monitor = WebsiteMonitor()
    
    print(f"Starting scheduled monitoring:")
    print(f"  Interval: {interval_minutes} minutes")
    print(f"  Max runs: {max_runs}")
    print(f"  Products: {len(urls)}\n")
    
    for run in range(max_runs):
        print(f"\n{'='*60}")
        print(f"Monitoring Run {run + 1}/{max_runs}")
        print(f"{'='*60}\n")
        
        # Perform monitoring
        monitor.monitor_products(urls)
        
        # Generate and display report
        if (run + 1) % 6 == 0:  # Every 6 runs
            print("\n" + monitor.generate_report())
        
        # Wait for next run (unless it's the last run)
        if run < max_runs - 1:
            wait_seconds = interval_minutes * 60
            print(f"Waiting {interval_minutes} minutes until next check...")
            time.sleep(wait_seconds)
    
    # Final report
    print("\n" + monitor.generate_report())


def main():
    """Main execution"""
    
    # URLs to monitor
    product_urls = [
        "https://www.amazon.com/dp/B0XXXXXX",  # Example product
        "https://www.bestbuy.com/site/product/12345",  # Example product
        # Add your product URLs here
    ]
    
    # Choose mode
    mode = input("Run mode? (1=single check, 2=scheduled monitoring): ").strip()
    
    if mode == "1":
        # Single monitoring check
        monitor = WebsiteMonitor()
        monitor.monitor_products(product_urls)
        print("\n" + monitor.generate_report())
    
    elif mode == "2":
        # Scheduled monitoring
        interval = int(input("Check interval in minutes (default 60): ") or "60")
        max_runs = int(input("Max number of runs (default 24): ") or "24")
        scheduled_monitoring(product_urls, interval, max_runs)
    
    else:
        print("Invalid mode selected")
        return 1
    
    return 0


if __name__ == "__main__":
    exit(main())
