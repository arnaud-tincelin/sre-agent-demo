using Azure.Monitor.OpenTelemetry.AspNetCore;

var builder = WebApplication.CreateBuilder(args);

// ── Observability ──────────────────────────────────────────────────────────────
// When APPLICATIONINSIGHTS_CONNECTION_STRING is present (set by infra in Azure),
// export logs, traces, and metrics to Azure Monitor / Application Insights so the
// SRE Agent can query them. Console logging always stays on, so the app's logs
// also flow to ContainerAppConsoleLogs_CL in Log Analytics.
if (!string.IsNullOrWhiteSpace(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
{
    builder.Services.AddOpenTelemetry().UseAzureMonitor();
}

builder.Services.AddCors(options =>
    options.AddDefaultPolicy(policy =>
        policy.WithOrigins("http://localhost:5173")
              .AllowAnyMethod()
              .AllowAnyHeader()));

var app = builder.Build();

app.UseCors();

// Log every incoming request so both Log Analytics and App Insights capture traffic.
app.Use(async (context, next) =>
{
    var logger = context.RequestServices.GetRequiredService<ILogger<Program>>();
    logger.LogInformation("HTTP {Method} {Path}", context.Request.Method, context.Request.Path);
    await next();
});

// ── Catalog ───────────────────────────────────────────────────────────────────

var catalog = new[]
{
    // Dogs 🐕
    new Product("1",  "Premium Dog Food",        29.99m, "Dogs",   "Grain-free chicken & sweet potato, 12 kg bag.",        "🦴"),
    new Product("2",  "Chew Bone Bundle",         12.49m, "Dogs",   "Long-lasting natural chews, pack of 6.",              "🦴"),
    new Product("3",  "Squeaky Plush Toy",         8.75m, "Dogs",   "Soft plush ball that squeaks. Machine washable.",     "🧸"),
    new Product("4",  "Cozy Dog Bed",             49.99m, "Dogs",   "Orthopedic memory-foam bed, size large.",             "🛏️"),
    new Product("5",  "Adjustable Leash",         18.00m, "Dogs",   "Reflective 2 m nylon leash with padded handle.",      "🐕"),
    new Product("6",  "Stainless Water Bowl",     14.25m, "Dogs",   "Non-slip stainless steel bowl, 1.5 L.",               "🥣"),

    // Cats 🐈
    new Product("7",  "Clumping Cat Litter",      15.50m, "Cats",   "Low-dust clumping clay litter, 10 kg.",               "🐾"),
    new Product("8",  "Feather Wand Toy",          6.99m, "Cats",   "Interactive teaser wand with replaceable feathers.",  "🪶"),
    new Product("9",  "Scratching Post Tower",    59.90m, "Cats",   "Multi-level sisal tower with cozy perch.",            "🗼"),
    new Product("10", "Salmon Cat Treats",         4.50m, "Cats",   "Grain-free freeze-dried salmon bites, 80 g.",         "🐟"),
    new Product("11", "Ceramic Cat Fountain",     34.99m, "Cats",   "Whisper-quiet 2 L drinking fountain.",                "⛲"),

    // Birds 🐦
    new Product("12", "Colorful Bird Toy",         8.75m, "Birds",  "Hanging bell & ladder toy for small parrots.",        "🪅"),
    new Product("13", "Premium Seed Mix",         11.20m, "Birds",  "Nutrient-rich seed blend, 2 kg resealable bag.",      "🌾"),
    new Product("14", "Wooden Bird Perch",         9.40m, "Birds",  "Natural hardwood perch, fits most cages.",            "🪵"),

    // Fish 🐠
    new Product("15", "Tropical Fish Flakes",      7.30m, "Fish",   "Color-enhancing daily flakes, 200 g.",                "🐠"),
    new Product("16", "LED Aquarium Light",       27.99m, "Fish",   "Full-spectrum clip-on light for planted tanks.",      "💡"),
    new Product("17", "Aquarium Gravel Set",      13.60m, "Fish",   "Natural river pebbles, 5 kg, aquarium-safe.",         "🪨"),

    // Small pets 🐹
    new Product("18", "Hamster Exercise Wheel",   10.99m, "Small",  "Silent spinner wheel for hamsters & gerbils.",        "🎡"),
    new Product("19", "Rabbit Hay Bundle",         8.20m, "Small",  "Timothy hay, high-fiber, 1 kg.",                      "🌿"),
    new Product("20", "Guinea Pig Hideout",       16.75m, "Small",  "Cozy wooden hideaway house for small pets.",          "🏠"),
};

// Listing the catalog is cheap and fast.
app.MapGet("/api/catalog", (ILogger<Program> logger) =>
{
    logger.LogInformation("Serving catalog with {ProductCount} products.", catalog.Length);
    return Results.Ok(catalog);
});

app.MapGet("/api/catalog/{id}", (string id, ILogger<Program> logger) =>
{
    var product = catalog.FirstOrDefault(p => p.Id == id);
    if (product is null)
    {
        return Results.NotFound();
    }

    logger.LogInformation("Opening product {ProductId} ({ProductName}).", product.Id, product.Name);
    return Results.Ok(product);
});

// ── Health check ──────────────────────────────────────────────────────────────

app.MapGet("/healthz", () => Results.Ok("ok"));

app.Logger.LogInformation("Zava backend started with {ProductCount} products in the catalog.", catalog.Length);

app.Run();

// ── Types ─────────────────────────────────────────────────────────────────────

record Product(string Id, string Name, decimal Price, string Category, string Description, string Emoji);
