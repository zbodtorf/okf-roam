---
type: Table
title: Users
description: One row per known product user.
resource: warehouse://product_analytics/users
tags: [users, identity, product]
timestamp: 2026-06-13T08:00:00Z
---

# Schema

| Column | Type | Description |
|---|---|---|
| `user_id` | string | Stable user identifier. |
| `created_at` | timestamp | Time the user was created in UTC. |
| `is_internal` | boolean | Whether the user belongs to the organization. |

# Related Concepts

- [Events](events.md)
- [Weekly Active Users](/metrics/weekly_active_users.md)
