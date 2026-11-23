# Threat model: 24/7 equity perps

**Scope.** This document models the *asset class*: a perpetual futures market for US equities that keeps trading while the underlying cash market is closed, reached through an app where users may fund in a local currency, convert to a dollar stablecoin, and take leveraged exposure. It is not an audit of any named company, product, chain or venue. It does not assert that any specific implementation has any of the issues below.

## 1. System sketch and trust boundaries

```
User (INR) --[onramp / KYC / FX]--> USDC --[venue]-- 24/7 equity perp
                                                  |
                    +-----------------------------+----------------------+
                    |                             |                      |
              equity oracle                 funding engine        margin / liquidation
              (price + age +                (hourly rate,           (health check,
               confidence)                  premium, clamp)         closeout, insurance)
                    |
              underlying cash market (opens/closes on a schedule, DST shifts)
```

Trust boundaries that matter for this analysis:

1. **Underlying market ↔ oracle.** The cash market stops producing prices on Friday and resumes Monday. Anything between those events is a model, not an observation.
2. **Oracle ↔ venue pricing.** The oracle's timestamp, confidence band and update queue are inputs to every mint, redeem and liquidation decision.
3. **Venue ↔ user.** Leverage, margin thresholds and the rules for forced closure are only fair if they are predictable during a period when the user cannot see a cash-market price.
4. **Local-currency onramp ↔ stablecoin balance.** FX/conversion settlement time and stablecoin transfer finality are separate from the perp's internal clock.

## 2. Why the weekend is structurally different

- **No reference price.** Friday's last cash price is real but old. Monday's open is real but not yet known. Every hour in between is a forecast with a widening confidence band.
- **No arbitrage tether.** During normal hours, a dislocation can be pulled back toward the underlying via cash/futures basis trades. With the cash market shut, that tether is absent.
- **Funding becomes price discovery.** With no underlying print, funding and premium carry more of the signal. A funding rate that is positive all weekend can still flip sign at the reopen.
- **News arrives on a closed book.** Company headlines, macro releases and geopolitical events frequently land when the underlying cannot trade.
- **DST moves the clock.** The UTC equivalent of 09:30 New York time changes twice a year. A hard-coded UTC window drifts by an hour unless it is DST-aware.
- **Thin liquidity amplifies moves.** Hourly candle ranges in our sample were up to 8.16% for NVDA, even though the Friday→Monday gap itself was 5.82%.

## 3. Risk register (asset-class level)

| Risk | Trigger | Who bears it | Generic control |
|---|---|---|---|
| Stale underlying quote | Friday price reused after weekend news | LPs / counterparty to the flow | Market-hours + max-age guard; reject mints/redeems on stale marks |
| Reopen gap | Monday price far from Friday close | Leveraged user, then insurance/venue | Gap-aware margin, staged reopen, circuit breakers, transparent warnings |
| Wide confidence interval | Oracle reports a midpoint with a large band | Whichever side trades at the midpoint | Reject quotes outside a confidence budget; size positions by the band |
| Update frontrunning | Queued price is visible before it is applied | Slow user / LP | Pending-update blocker, batching, commit-reveal, or auction-based pricing |
| Guard-induced halt | Market-closed guard blocks a legitimate exit | User who needs liquidity | Clear published rules, emergency redemption path, post-reopen settlement |
| Funding surprise | Funding sign/size changes over the weekend | Long or short position holder | Funding caps, disclosure of cumulative expected funding, honest simulated cost |
| Liquidation timing | Forced close on a pre-open or stale mark | Leveraged user | Require fresh + in-hours quote for liquidation; grace period around reopen |
| FX / onramp delay | Local-currency deposit settles slower than stablecoin leg | User | Show settlement state; separate "funded" from "tradable" balances |
| Data limits | 500-element / 5,000-candle API windows | Researcher / risk dashboard | Paginate; archive raw responses; never treat a partial window as complete |

## 4. Attack trees (generic, illustrated by the PoCs in `test/`)

### 4.1 Stale Friday close after weekend news
- Precondition: a quote from Friday remains the executable price on Saturday.
- Steps: news moves true value → actor trades at the stale quote → oracle updates at reopen → actor closes at the new price.
- Countermeasure demonstrated: market-hours guard refuses the weekend trade; staleness guard refuses an old quote even during hours.

### 4.2 Wide confidence interval abuse
- Precondition: midpoint is executable even when the stated uncertainty is large.
- Steps: actor trades at midpoint → resolved price lands at the favourable end of the band → counterparty absorbs difference.
- Countermeasure demonstrated: confidence guard rejects quotes wider than a configured basis-point budget.

### 4.3 Oracle update frontrunning
- Precondition: a pending reprice is observable before it lands on-chain.
- Steps: actor observes queued price → trades at old price → keeper applies new price → actor closes.
- Countermeasure demonstrated: pending-update blocker refuses mint/redeem while an update is queued. In a production design this would be a batching/auction or commit-reveal mechanism, not merely a UI hint.

### 4.4 Monday reopen-gap liquidation
- Precondition: 50x leverage leaves about 2% margin; a gap above roughly 2% is larger than the entire margin.
- Steps: user is healthy on Friday → underlying falls over the weekend → first executable price at reopen is materially lower → health check trips immediately.
- Countermeasure demonstrated: liquidation must use a guarded quote (in-hours, fresh, tight, no pending update); a weekend or pre-open quote cannot be used to seize collateral.

### 4.5 Guard-halts-redemption edge case
- Precondition: the same guard that blocks bad pricing also blocks a user's exit.
- Failure mode: controls protect LPs but trap users indefinitely.
- Countermeasure demonstrated: the halt must be temporary and must resolve automatically when market hours reopen and a fresh quote is available.

## 5. Invariants worth demanding from any such design

1. No mint, redeem or force-close may use a quote whose **age**, **confidence** or **market-hours status** is invalid.
2. The price used for liquidation must be the **same** price a user could have used to close voluntarily at that moment.
3. Funding shown to users must be the **cumulative expected cost over the holding period**, not just the current hourly print.
4. Any guard that pauses redemption must have a **defined, public resumption condition**.
5. Dashboards must archive raw data; truncated API windows must be labelled as truncated.
6. User-facing warnings should be denominated in the user's **margin**, e.g. "a 2% gap removes 100% of margin at 50x", not just in price percentage.

## 6. Residual risks and limits of this research

- The Solidity vault in `src/` is a **mock**: the oracle, USDC token and lender are test doubles. It is a teaching instrument, not deployable infrastructure.
- Market hours in the contract are DST-aware US Eastern (second Sunday of March to first Sunday of November), but there is no exchange holiday calendar and no early-close handling; a production system needs both.
- The data section uses perp candles as a proxy for cash-market close/open. Official exchange settlement prices and index construction rules are outside the public info API used here.
- We make no claim about the implementation, controls or behaviour of any named company. The risk theme is generic to the product category.
