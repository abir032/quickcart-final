variable "alert_email" {
  description = "Who is told when spending passes the budget"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Expected monthly spend. You're emailed at 80% of it, and when AWS forecasts going over."
  type        = number
  default     = 100
}
