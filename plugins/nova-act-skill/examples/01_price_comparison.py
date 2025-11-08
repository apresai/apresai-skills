#!/usr/bin/env python3
"""
Nova Act Example: Product Price Comparison

This script searches for a product across multiple e-commerce sites,
extracts pricing and availability information, and compares them.

Prerequisites:
- Nova Act SDK: pip install nova-act
- API key: export NOVA_ACT_API_KEY="your_key"
"""

from nova_act import NovaAct, ActError
from pydantic import BaseModel
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional
import json


class ProductInfo(BaseModel):
    """Data model for product information"""
    site: str
    product_name: str
    price: float
    in_stock: bool
    rating: Optional[float] = None
    url: str


def search_amazon(product_query: str) -> Optional[ProductInfo]:
    """Search for product on Amazon"""
    try:
        with NovaAct(
            starting_page="https://www.amazon.com",
            headless=True,
            logs_directory="./logs/amazon"
        ) as nova:
            # Step 1: Search for the product
            nova.act(f"search for {product_query}")
            
            # Step 2: Click on first result
            nova.act("click on the first product result")
            
            # Step 3: Extract product information
            result = nova.act(
                "Extract the product title, price (as a number), stock status (true if in stock), "
                "and customer rating (as a number out of 5)",
                schema=ProductInfo.model_json_schema()
            )
            
            if result.matches_schema:
                product = ProductInfo.model_validate(result.parsed_response)
                product.site = "Amazon"
                product.url = nova.page.url
                return product
            else:
                print(f"Amazon: Failed to extract structured data")
                return None
                
    except ActError as e:
        print(f"Amazon error: {e}")
        return None


def search_bestbuy(product_query: str) -> Optional[ProductInfo]:
    """Search for product on Best Buy"""
    try:
        with NovaAct(
            starting_page="https://www.bestbuy.com",
            headless=True,
            logs_directory="./logs/bestbuy"
        ) as nova:
            # Step 1: Search for the product
            nova.act(f"search for {product_query} and press enter")
            
            # Step 2: Click on first result
            nova.act("click on the first product")
            
            # Step 3: Extract product information
            result = nova.act(
                "Extract the product name, price (as a number), "
                "whether it's in stock (true/false), and customer rating",
                schema=ProductInfo.model_json_schema()
            )
            
            if result.matches_schema:
                product = ProductInfo.model_validate(result.parsed_response)
                product.site = "Best Buy"
                product.url = nova.page.url
                return product
            else:
                print(f"Best Buy: Failed to extract structured data")
                return None
                
    except ActError as e:
        print(f"Best Buy error: {e}")
        return None


def search_target(product_query: str) -> Optional[ProductInfo]:
    """Search for product on Target"""
    try:
        with NovaAct(
            starting_page="https://www.target.com",
            headless=True,
            logs_directory="./logs/target"
        ) as nova:
            # Step 1: Search for the product
            nova.act(f"search for {product_query}")
            
            # Step 2: Click on first result
            nova.act("click on the first product in the results")
            
            # Step 3: Extract product information
            result = nova.act(
                "Get the product name, current price (number only), "
                "availability status (in stock = true), and star rating",
                schema=ProductInfo.model_json_schema()
            )
            
            if result.matches_schema:
                product = ProductInfo.model_validate(result.parsed_response)
                product.site = "Target"
                product.url = nova.page.url
                return product
            else:
                print(f"Target: Failed to extract structured data")
                return None
                
    except ActError as e:
        print(f"Target error: {e}")
        return None


def compare_prices(product_query: str) -> list[ProductInfo]:
    """
    Search for a product across multiple sites in parallel
    and return comparison results.
    """
    print(f"Searching for '{product_query}' across multiple retailers...")
    print("=" * 60)
    
    results = []
    
    # Run searches in parallel for speed
    with ThreadPoolExecutor(max_workers=3) as executor:
        # Submit all search tasks
        futures = {
            executor.submit(search_amazon, product_query): "Amazon",
            executor.submit(search_bestbuy, product_query): "Best Buy",
            executor.submit(search_target, product_query): "Target",
        }
        
        # Collect results as they complete
        for future in as_completed(futures):
            site_name = futures[future]
            try:
                product_info = future.result()
                if product_info:
                    results.append(product_info)
                    print(f"✓ {site_name}: Found product")
                else:
                    print(f"✗ {site_name}: No data extracted")
            except Exception as e:
                print(f"✗ {site_name}: Error - {e}")
    
    return results


def display_comparison(products: list[ProductInfo]):
    """Display comparison results in a formatted table"""
    if not products:
        print("\nNo products found!")
        return
    
    print("\n" + "=" * 60)
    print("PRICE COMPARISON RESULTS")
    print("=" * 60 + "\n")
    
    # Sort by price (lowest first)
    sorted_products = sorted(products, key=lambda p: p.price)
    
    for i, product in enumerate(sorted_products, 1):
        print(f"{i}. {product.site}")
        print(f"   Product: {product.product_name}")
        print(f"   Price: ${product.price:.2f}")
        print(f"   In Stock: {'Yes' if product.in_stock else 'No'}")
        if product.rating:
            print(f"   Rating: {product.rating}/5.0")
        print(f"   URL: {product.url}")
        print()
    
    # Show savings
    if len(sorted_products) > 1:
        cheapest = sorted_products[0]
        most_expensive = sorted_products[-1]
        savings = most_expensive.price - cheapest.price
        
        print("=" * 60)
        print(f"Best Deal: {cheapest.site} at ${cheapest.price:.2f}")
        print(f"Savings: ${savings:.2f} vs most expensive option")
        print("=" * 60)


def save_results_json(products: list[ProductInfo], filename: str = "price_comparison.json"):
    """Save comparison results to JSON file"""
    with open(filename, 'w') as f:
        json.dump(
            [p.model_dump() for p in products],
            f,
            indent=2
        )
    print(f"\nResults saved to {filename}")


def main():
    """Main execution"""
    # Product to search for
    product_query = "Sony WH-1000XM5 headphones"
    
    # Perform comparison
    results = compare_prices(product_query)
    
    # Display results
    display_comparison(results)
    
    # Save to JSON
    if results:
        save_results_json(results)
    
    return 0 if results else 1


if __name__ == "__main__":
    exit(main())
