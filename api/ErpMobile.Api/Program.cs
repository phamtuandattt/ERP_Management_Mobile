using System.Text;
using ErpMobile.Api;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

var jwtKey = builder.Configuration["Jwt:Key"] ?? "";
var issuer = builder.Configuration["Jwt:Issuer"] ?? "ErpMobile";
var audience = builder.Configuration["Jwt:Audience"] ?? "ErpMobile";

builder.Services.AddSingleton<ErpData>();
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = null;
});
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateIssuerSigningKey = true,
            ValidateLifetime = true,
            ValidIssuer = issuer,
            ValidAudience = audience,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(
                string.IsNullOrWhiteSpace(jwtKey) ? "dev-only-erp-mobile-key-change-before-share-32" : jwtKey))
        };
    });
builder.Services.AddAuthorization();
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy => policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod());
});

var app = builder.Build();
app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

app.MapPost("/api/auth/login", async (LoginRequest body, ErpData data) =>
{
    try
    {
        return Results.Ok(await data.LoginAsync(body.Username, body.Password));
    }
    catch (AuthException ex)
    {
        return Results.Json(new { message = ex.Message }, statusCode: ex.StatusCode);
    }
    catch (InvalidOperationException ex)
    {
        return Results.Problem(ex.Message, statusCode: StatusCodes.Status500InternalServerError);
    }
});

app.MapGet("/api/projects", async (HttpContext http, ErpData data) =>
{
    try
    {
        await data.EnsureWarehouseAccessAsync(http.User);
        return Results.Ok(await data.GetProjectsAsync());
    }
    catch (AuthException ex)
    {
        return Results.Json(new { message = ex.Message }, statusCode: ex.StatusCode);
    }
}).RequireAuthorization();

app.MapGet("/api/warehouse/stock", async (string? projectCode, string? keyword, HttpContext http, ErpData data) =>
{
    try
    {
        await data.EnsureWarehouseAccessAsync(http.User);
        return Results.Ok(await data.GetStockAsync(projectCode, keyword));
    }
    catch (AuthException ex)
    {
        return Results.Json(new { message = ex.Message }, statusCode: ex.StatusCode);
    }
}).RequireAuthorization();

app.Run();
