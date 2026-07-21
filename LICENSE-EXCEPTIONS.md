# License exceptions

> **Not legal advice.** This is the project's stated intent, drafted by the
> maintainers. If you are relying on it commercially, have your own counsel
> read it.

## App store additional permission (GNU AGPL v3, section 7)

The following additional permission applies to the AGPL-3.0-licensed portions of
this repository — the app targets `App/` (EldrChat) and `Apps/Huginn/`, and any
other AGPL-covered work here (see [`LICENSING.md`](LICENSING.md)). It is granted
by the copyright holders as an "additional permission" under section 7 of the
GNU Affero General Public License, version 3:

> As an additional permission under section 7, you are allowed to distribute
> the software through an app store, even if that store has restrictive terms
> and conditions that are incompatible with the AGPL, provided that the source
> is also available under the AGPL with or without this permission through a
> channel without those restrictive terms and conditions.

### Why this exists

Apple's App Store terms impose usage restrictions (device limits, DRM,
anti-reverse-engineering clauses) that conflict with the AGPL's guarantee that
recipients may run, modify, and redistribute freely. Without an explicit
additional permission, shipping AGPL software through the App Store is a
license violation — this is the same conflict behind the FSF's 2010 App Store
GPL enforcement actions. This permission resolves it in the narrow case of app
store distribution, **while keeping the AGPL source obligation fully intact**:
the complete corresponding source must remain available under the AGPL through
a channel without those restrictions (for this project, the public repository).

As provided by section 7 of the AGPLv3, when you convey a copy of a covered
work you may at your option remove this additional permission from your copy.
