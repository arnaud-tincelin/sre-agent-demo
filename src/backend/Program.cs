var builder = WebApplication.CreateBuilder(args);

builder.Services.AddCors(options =>
    options.AddDefaultPolicy(policy =>
        policy.WithOrigins("http://localhost:5173")
              .AllowAnyMethod()
              .AllowAnyHeader()));

var app = builder.Build();

app.UseCors();

// ── Catalog ───────────────────────────────────────────────────────────────────

var catalog = new[]
{
    new Product("1", "Dog food",  29.99m),
    new Product("2", "Cat litter", 15.50m),
    new Product("3", "Bird toy",    8.75m),
};

app.MapGet("/api/catalog", (ILogger<Program> logger) =>
{
    // Intentional bug for the SRE demo: called on every catalog request.
    AVeryMemoryIntensiveFunction(logger);
    return Results.Ok(catalog);
});

// ── Health check ──────────────────────────────────────────────────────────────

app.MapGet("/healthz", () => Results.Ok("ok"));

app.Run();

// ── Memory leak ───────────────────────────────────────────────────────────────

static class LeakBucket
{
    public static readonly List<byte[]> Items = [];
}

static void AVeryMemoryIntensiveFunction(ILogger logger)
{
    LeakBucket.Items.Add(new byte[10_000_000]); // 10 MB per call, never released
    var leakSize = LeakBucket.Items.Count;
    logger.LogError("AVeryMemoryIntensiveFunction leak size={LeakSize}", leakSize);
}

// ── Types ─────────────────────────────────────────────────────────────────────

record Product(string Id, string Name, decimal Price);
