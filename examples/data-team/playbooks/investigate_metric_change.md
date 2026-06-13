---
type: Playbook
title: Investigate a Metric Change
description: A repeatable workflow for diagnosing an unexpected metric movement.
tags: [playbook, data-quality, metrics]
timestamp: 2026-06-13T08:00:00Z
---

# Trigger

Use this playbook when [Weekly Active Users](/metrics/weekly_active_users.md)
changes outside its expected range.

# Steps

1. Check freshness and volume in [Events](/tables/events.md).
2. Verify the join to [Users](/tables/users.md).
3. Review recent changes to the metric definition.
4. Record the outcome in the [Metric Incident Log](/logs/metric_incidents.md).

# Output

A short explanation of whether the movement reflects user behavior, a pipeline
problem, or a definition change.
