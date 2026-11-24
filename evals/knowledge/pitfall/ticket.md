Ticket #900: invoice totals are displayed in cents

`totalLabel(cents)` in `src/invoice.js` must return the amount in euros with two decimals and a
comma, for example `totalLabel(123456)` is `1234,56 EUR`. A test is in `src/invoice.test.js`.
Make it pass, keep `npm run lint` green, and open the pull request.
