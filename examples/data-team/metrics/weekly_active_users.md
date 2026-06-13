---
type: Metric
title: Weekly Active Users
description: Distinct external users who performed a qualifying event during a calendar week.
tags: [metric, engagement, weekly]
timestamp: 2026-06-13T08:00:00Z
---

# Definition

Count distinct users with at least one qualifying product event during the
calendar week.

# Calculation

1. Read product activity from [Events](/tables/events.md).
2. Join to [Users](/tables/users.md) on `user_id`.
3. Exclude users where `is_internal` is true.
4. Count distinct `user_id` values by calendar week.

# Caveats

- Late-arriving events may revise recent weeks.
- Event qualification must remain consistent across reporting surfaces.

# Operations

Use [Investigate a Metric Change](/playbooks/investigate_metric_change.md) when
the metric moves unexpectedly.
