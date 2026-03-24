# VendorBulkBuy

VendorBulkBuy is a small Turtle WoW addon that lets you Shift-click a vendor item, type the amount you want, and buy more than the default limit.

## Release Version

- Version: 1.1
- Status: Release version
- Compatible with: Turtle WoW 1.18.1

## What It Does

- opens a custom amount popup when you Shift-click a vendor item
- supports very large purchases by splitting the buy into multiple vendor calls
- asks for confirmation before purchases above 20
- works with vendor pack sizes automatically

## How To Use

1. Open a vendor on the buy tab.
2. Shift-click the item you want to buy.
3. Enter the amount you want in the popup.
4. If the amount is above 20, confirm the purchase in the second prompt.

## Notes

- Items sold in bundles are handled using the vendor's pack size.
- Very large purchases are completed in multiple internal buy calls.
- This release uses the custom popup flow instead of relying on the default stack-split box.