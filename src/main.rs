use main_error::MainError;
use reqwest::Response;
use serde_json::Value;
use sqlx::postgres::PgPool;
use std::time::Duration;
use tokio::time::delay_for;

#[tokio::main]
async fn main() -> Result<(), MainError> {
    let pool = PgPool::builder()
        .max_size(2)
        .build(&dotenv::var("DATABASE_URL")?)
        .await?;

    let client = reqwest::Client::new();

    let row = sqlx::query!("SELECT MAX(id) AS last_archived FROM logs_raw")
        .fetch_one(&pool)
        .await?;

    let last_demo = 2510323; // TODO dynamically determine this

    let mut last_archived = row.last_archived.unwrap_or_default();

    while last_archived <= last_demo {
        last_archived += 1;

        println!("{}", last_archived);

        delay_for(Duration::from_millis(200)).await;

        let response: Response = client
            .get(&format!(
                "https://logstf.vrchat.network/api/v1/log/{}",
                last_archived
            ))
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
