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

// ── Platform configuration ────────────────────────────────────────────────────
// CATALOG_SOURCE selects the catalog provider and is supplied by the platform as
// a Container Apps environment variable. "builtin" is the only provider this
// build ships with. CONTAINER_APP_REVISION is injected by Azure Container Apps.
const string SupportedCatalogSource = "builtin";
var catalogSource = builder.Configuration["CATALOG_SOURCE"] ?? SupportedCatalogSource;
var revision = builder.Configuration["CONTAINER_APP_REVISION"] ?? "local";
var catalogSourceValid = string.Equals(catalogSource, SupportedCatalogSource, StringComparison.OrdinalIgnoreCase);

var app = builder.Build();

app.UseCors();

// Log every incoming request so both Log Analytics and App Insights capture traffic.
// Health probes are excluded: the storefront polls them every few seconds and the
// noise would bury the request pattern an investigation actually needs.
app.Use(async (context, next) =>
{
    var path = context.Request.Path;
    if (!path.StartsWithSegments("/api/health") && !path.StartsWithSegments("/healthz"))
    {
        var logger = context.RequestServices.GetRequiredService<ILogger<Program>>();
        logger.LogInformation("HTTP {Method} {Path}", context.Request.Method, path);
    }

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

// Returned when the platform hands the app a catalog provider it cannot serve.
IResult CatalogSourceUnavailable(ILogger logger)
{
    logger.LogError(
        "CONFIG_ERROR CatalogSource='{CatalogSource}' is not a supported provider on revision {Revision}; expected '{Expected}'.",
        catalogSource,
        revision,
        SupportedCatalogSource);

    return Results.Problem(
        title: "Catalog unavailable",
        detail: $"CATALOG_SOURCE '{catalogSource}' is not a supported catalog provider.",
        statusCode: StatusCodes.Status503ServiceUnavailable);
}

// Listing the catalog is cheap and fast.
app.MapGet("/api/catalog", IResult (ILogger<Program> logger) =>
{
    if (!catalogSourceValid)
    {
        return CatalogSourceUnavailable(logger);
    }

    logger.LogInformation("Serving catalog with {ProductCount} products.", catalog.Length);
    return Results.Ok(catalog);
});

// Opening a product page applies the running autumn campaign discount.
app.MapGet("/api/catalog/{id}", IResult (string id, ILogger<Program> logger) =>
{
    if (!catalogSourceValid)
    {
        return CatalogSourceUnavailable(logger);
    }

    var product = catalog.FirstOrDefault(p => p.Id == id);
    if (product is null)
    {
        return Results.NotFound();
    }

    logger.LogInformation("Opening product {ProductId} ({ProductName}).", product.Id, product.Name);

    var promoRate = Promotions.RatesByCategory[product.Category];
    var promoPrice = Math.Round(product.Price * (1 - promoRate), 2);

    return Results.Ok(new ProductDetail(
        product.Id,
        product.Name,
        product.Price,
        product.Category,
        product.Description,
        product.Emoji,
        promoRate,
        promoPrice));
});

// ── Health ────────────────────────────────────────────────────────────────────
// /api/health is the storefront-facing check: it always returns a JSON body the
// UI can render, and switches to 503 when the app is misconfigured so the outage
// shows up in AppRequests. /healthz stays a flat 200 for platform probes.
app.MapGet("/api/health", IResult (ILogger<Program> logger) =>
{
    var payload = new
    {
        status = catalogSourceValid ? "healthy" : "unhealthy",
        catalogSource,
        expectedCatalogSource = SupportedCatalogSource,
        productCount = catalogSourceValid ? catalog.Length : 0,
        revision,
        reason = catalogSourceValid
            ? null
            : $"CONFIG_ERROR CatalogSource='{catalogSource}' is not a supported provider; expected '{SupportedCatalogSource}'.",
    };

    if (!catalogSourceValid)
    {
        logger.LogError(
            "Health check failed: CONFIG_ERROR CatalogSource='{CatalogSource}' on revision {Revision}; expected '{Expected}'.",
            catalogSource,
            revision,
            SupportedCatalogSource);

        return Results.Json(payload, statusCode: StatusCodes.Status503ServiceUnavailable);
    }

    return Results.Ok(payload);
});

app.MapGet("/healthz", () => Results.Ok("ok"));

app.Logger.LogInformation(
    "Zava backend started on revision {Revision} with catalog source '{CatalogSource}' and {ProductCount} products.",
    revision,
    catalogSource,
    catalog.Length);

app.Run();

// ── Types ─────────────────────────────────────────────────────────────────────

// Autumn campaign discounts, keyed by catalog category.
static class Promotions
{
    public static readonly Dictionary<string, decimal> RatesByCategory = new()
    {
        ["Dogs"] = 0.10m,
        ["Cats"] = 0.10m,
        ["Birds"] = 0.05m,
        ["Fish"] = 0.05m,
    };
}

record Product(string Id, string Name, decimal Price, string Category, string Description, string Emoji);

record ProductDetail(
    string Id,
    string Name,
    decimal Price,
    string Category,
    string Description,
    string Emoji,
    decimal PromoRate,
    decimal PromoPrice);
