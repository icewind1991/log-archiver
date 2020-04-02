use chrono::{DateTime, Utc};
use main_error::MainError;
use reqwest::{Client, Response};
use serde::Deserialize;
use serde_json::Value;
use sqlx::postgres::PgPool;
use std::time::Duration;
use tokio::time::delay_for;

#[tokio::main]
async fn main() -> Result<(), MainError> {
    let database_url = dotenv::var("DATABASE_URL")?;
    let api_base =
        dotenv::var("API_BASE").unwrap_or_else(|_| "http://logs.tf/api/v1/log".to_string());

    loop {
        if let Err(e) = archive(&database_url, &api_base).await {
            eprintln!("{:?}", e);
        }

        delay_for(Duration::from_secs(60)).await;
    }
}

async fn get_last_demo(client: &Client, api_base: &str) -> Result<i32, MainError> {
    let response: Response = client
        .get(&format!("{}?limit=100", api_base))
        .send()
        .await?;
    let listing: LogListing = serde_json::from_str(&response.text().await?)?;
    let logs = match listing.success {
        true => listing.logs,
        false => return Err("Failed to list logs")?,
    };

    let now = Utc::now();

    // take a demo from at least 1h ago since ongoing games can update their demos
    let last_log = logs
        .into_iter()
        .find(|log| now.signed_duration_since(log.date) > chrono::Duration::seconds(3600));

    Ok(last_log.ok_or("Failed to find last log")?.id)
}

async fn archive(database_url: &str, api_base: &str) -> Result<(), MainError> {
    let pool = PgPool::builder().max_size(2).build(database_url).await?;

    let client = reqwest::Client::new();

    let row = sqlx::query!("SELECT MAX(id) AS last_archived FROM logs_raw")
        .fetch_one(&pool)
        .await?;

    let last_demo = get_last_demo(&client, api_base).await?;
    println!("Archiving up to log {}", last_demo);

    let mut last_archived = row.last_archived.unwrap_or_default();

    while last_archived <= last_demo {
        last_archived += 1;

        println!("{}", last_archived);

        delay_for(Duration::from_millis(200)).await;

        let response: Response = client
            .get(&format!("{}/{}", api_base, last_archived))
            .send()
            .await?;
        let body: Value = serde_json::from_str(&response.text().await?)?;

        sqlx::query!(
            "INSERT INTO logs_raw(id, json) VALUES($1, $2)",
            last_archived,
            body
        )
        .execute(&pool)
        .await?;
    }

    Ok(())
}

#[derive(Debug, Deserialize)]
struct LogListing {
    success: bool,
    logs: Vec<LogInfo>,
}

#[derive(Debug, Deserialize)]
struct LogInfo {
    id: i32,
    #[serde(with = "chrono::serde::ts_seconds")]
    date: DateTime<Utc>,
}
