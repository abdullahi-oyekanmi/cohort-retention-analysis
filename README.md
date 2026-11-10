# Cohort Retention Analysis - Identifying Churn Rate, Churn Concentration and On-boarding Call Intervention Impact on Retention

## Project Overview
Cohort retention analysis for a SaaS helpdesk company to identify who is churning, where it is concentrated, and whether onboarding calls help with retention.

Data Source: Provided case-study data for a fictional company.

## Business Question
1. Do newer signup cohorts retain worse than older ones? 
2. Where is churn concentrated (plan, channel)? 
3. Are accounts that had an onboarding call retained better?

## Key Findings
* Newer customers retain worse: 68% of March to June signups were retained at month 3, versus 81% of October to February signups.
* Early churn is concentrated in the Basic plan (48% of accounts but 66% of those lost by month 3) and in Paid Ads signups (30% of accounts but 41% of those lost by month 3), and both remain the weakest at month 6.
* Accounts that had an onboarding call retained 18 points better at month 3 (83% vs 65%), and the gap holds within every plan, but calls may not have been randomly assigned, so this shows an association, not proof that calls work.

## Recommendation
* A randomized test: give a call to a random half of the next new Basic and Paid Ads signups, and compare month-3 retention between the two groups. 

## Limitations and Assumptions 
* Calls: association, not proof. Calls may not have been randomly assigned, and how accounts were chosen is unknown.

* Limited history for newer cohorts. 

* Failed payments are counted as active. 

* The data shows where churn is concentrated, not why.

## Tools Used:
* SQL (PostgreSQL): Data profiling, cleaning, and analysis.
* Tableau: Data visualizations.

## Repository contents
* definitions_and_logs.docx: cleaning log, definitions, assumptions and limits.
* cohort-retention-analysis.sql: all SQL queries, in order, with comments.
* Visualizations (folder): Visualizations screenshots.
* Data (folder): the three CSVs.
* Tableau Public Link >> 
