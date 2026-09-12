// Fixture for the «follows-repo-conventions» case: deliberately written against common conventions.
export function total(items) {
  var sum = 0
  for (var i = 0; i < items.length; i++) {
    sum = sum + items[i].price
  }
  console.log("total", sum)
  return sum
}
