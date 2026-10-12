using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.IdentityModel.Tokens;

namespace ErpMobile.Api;

public sealed class ErpData
{
    private readonly string _connectionString;
    private readonly string _jwtKey;
    private readonly string _issuer;
    private readonly string _audience;
    private readonly int _hours;

    public ErpData(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? "";
        _jwtKey = configuration["Jwt:Key"] ?? "";
        _issuer = configuration["Jwt:Issuer"] ?? "ErpMobile";
        _audience = configuration["Jwt:Audience"] ?? "ErpMobile";
        _hours = int.TryParse(configuration["Jwt:Hours"], out var hours) ? hours : 12;
    }

    public void EnsureConfigured()
    {
        if (string.IsNullOrWhiteSpace(_connectionString))
            throw new InvalidOperationException("Chưa cấu hình ConnectionStrings:DefaultConnection.");
        if (string.IsNullOrWhiteSpace(_jwtKey) || Encoding.UTF8.GetByteCount(_jwtKey) < 32)
            throw new InvalidOperationException("Jwt:Key phải có ít nhất 32 byte.");
    }

    public async Task<LoginResponse> LoginAsync(string username, string password)
    {
        EnsureConfigured();
        var name = (username ?? "").Trim();
        if (name.Length == 0 || string.IsNullOrEmpty(password))
            throw new AuthException(StatusCodes.Status401Unauthorized, "Sai tên đăng nhập hoặc mật khẩu!");

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync();

        await using var cmd = new SqlCommand("sp_Login", conn) { CommandType = System.Data.CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@Username", name);
        cmd.Parameters.AddWithValue("@Password_Hash", HashPassword(password));

        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
            throw new AuthException(StatusCodes.Status401Unauthorized, "Không có phản hồi từ server");

        var result = reader["Result"]?.ToString() ?? "";
        if (!string.Equals(result, "SUCCESS", StringComparison.OrdinalIgnoreCase))
        {
            var message = result switch
            {
                "INVALID_CREDENTIALS" => "Sai tên đăng nhập hoặc mật khẩu!",
                "ACCOUNT_DISABLED" => "Tài khoản đã bị vô hiệu hóa!",
                _ => "Đăng nhập thất bại!"
            };
            throw new AuthException(StatusCodes.Status401Unauthorized, message);
        }

        var userId = Convert.ToInt32(reader["User_ID"]);
        var fullName = reader["Full_Name"]?.ToString() ?? "";
        var roleId = Convert.ToInt32(reader["Role_ID"]);
        var roleName = reader["Role_Name"]?.ToString() ?? "";
        await reader.CloseAsync();

        if (!await CanViewWarehouseAsync(conn, userId, name, roleId, roleName))
            throw new AuthException(StatusCodes.Status403Forbidden, "Bạn không có quyền xem kho.");

        return new LoginResponse
        {
            Token = CreateToken(userId, name, fullName, roleId, roleName),
            Username = name,
            FullName = fullName
        };
    }

    public async Task EnsureWarehouseAccessAsync(ClaimsPrincipal user)
    {
        EnsureConfigured();
        var username = user.FindFirstValue(ClaimTypes.Name) ?? "";
        var roleName = user.FindFirstValue("role_name") ?? "";
        var roleId = int.TryParse(user.FindFirstValue("role_id"), out var parsed) ? parsed : 0;
        var userId = int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var id) ? id : 0;
        if (IsAdmin(username, roleId, roleName))
            return;

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync();
        if (!await CanViewWarehouseAsync(conn, userId, username, roleId, roleName))
            throw new AuthException(StatusCodes.Status403Forbidden, "Bạn không có quyền xem kho.");
    }

    public async Task<List<ProjectItem>> GetProjectsAsync()
    {
        EnsureConfigured();
        await using var conn = new SqlConnection(_connectionString);
        var rows = await conn.QueryAsync<ProjectItem>(
            "SELECT ProjectCode, ISNULL(ProjectName, N'') AS ProjectName FROM ProjectInfo ORDER BY ProjectCode");
        return rows.AsList();
    }

    public async Task<StockResult> GetStockAsync(string? projectCode, string? keyword)
    {
        EnsureConfigured();
        var project = projectCode?.Trim() ?? "";
        var text = keyword?.Trim() ?? "";
        await using var conn = new SqlConnection(_connectionString);
        var rows = await conn.QueryAsync<StockItem>(@"
            SELECT s.Import_ID, s.Import_No, s.Import_Date, s.Item_Name, s.Material, s.Size, s.UNIT,
                   s.Qty_Import, s.Qty_Exported, s.Qty_Stock, s.Weight_Stock,
                   ISNULL(s.QC_Code, N'') AS QC_Code,
                   ISNULL(s.QC_Status, N'') AS QC_Status,
                   ISNULL(s.Remarks, N'') AS Remarks,
                   ISNULL(rir.RIR_No, N'') AS RIR_No,
                   ISNULL(rir.Status, N'Chưa tạo RIR') AS RIR_Status,
                   s.Project_Code, s.PONo
            FROM vw_Warehouse_Stock_V2 s
            LEFT JOIN Warehouse_Import wi ON wi.Import_ID = s.Import_ID
            OUTER APPLY (
                SELECT TOP 1 h.RIR_No, h.Status
                FROM RIR_head h
                WHERE (wi.RIR_ID IS NOT NULL AND h.RIR_ID = wi.RIR_ID)
                   OR (
                        wi.PO_Detail_ID IS NOT NULL
                        AND EXISTS (
                            SELECT 1
                            FROM RIR_detail d
                            WHERE d.RIR_ID = h.RIR_ID AND d.PO_Detail_ID = wi.PO_Detail_ID
                        )
                   )
                ORDER BY CASE WHEN wi.RIR_ID IS NOT NULL AND h.RIR_ID = wi.RIR_ID THEN 0 ELSE 1 END,
                         h.RIR_ID DESC
            ) rir
            WHERE (@proj = '' OR s.Project_Code = @proj)
              AND (@kw = '' OR s.Size LIKE @kwPat OR s.Material LIKE @kwPat OR s.Item_Name LIKE @kwPat
                   OR s.ID_Code LIKE @kwPat OR s.Import_No LIKE @kwPat OR s.PONo LIKE @kwPat)
            ORDER BY s.Import_Date DESC",
            new { proj = project, kw = text, kwPat = $"%{text}%" });

        var items = rows.AsList();
        return new StockResult
        {
            Count = items.Count,
            QtyStock = items.Sum(x => x.Qty_Stock),
            WeightStock = items.Sum(x => x.Weight_Stock),
            Items = items
        };
    }

    private static async Task<bool> CanViewWarehouseAsync(SqlConnection conn, int userId, string username, int roleId, string roleName)
    {
        if (IsAdmin(username, roleId, roleName))
            return true;

        var detailed = (await conn.QueryAsync<(string Module_Code, string Action_Name, bool Is_Granted)>(
            "SELECT Module_Code, Action_Name, Is_Granted FROM User_Detailed_Permissions WHERE User_ID = @UserId",
            new { UserId = userId })).AsList();

        if (detailed.Count > 0)
        {
            return detailed.Any(x =>
                string.Equals(x.Module_Code, "WAREHOUSE", StringComparison.OrdinalIgnoreCase)
                && string.Equals(x.Action_Name, "Xem", StringComparison.OrdinalIgnoreCase)
                && x.Is_Granted);
        }

        var view = await conn.ExecuteScalarAsync<int?>(@"
            SELECT TOP 1 1
            FROM vw_User_Effective_Permissions
            WHERE User_ID = @UserId
              AND Module_Code = 'WAREHOUSE'
              AND Can_View = 1",
            new { UserId = userId });
        return view.HasValue;
    }

    private static bool IsAdmin(string username, int roleId, string roleName) =>
        roleId == 1
        || string.Equals(roleName, "Admin", StringComparison.OrdinalIgnoreCase)
        || string.Equals(roleName, "Administrator", StringComparison.OrdinalIgnoreCase)
        || string.Equals(username, "admin", StringComparison.OrdinalIgnoreCase);

    private string CreateToken(int userId, string username, string fullName, int roleId, string roleName)
    {
        var claims = new[]
        {
            new Claim(ClaimTypes.NameIdentifier, userId.ToString()),
            new Claim(ClaimTypes.Name, username),
            new Claim(ClaimTypes.GivenName, fullName),
            new Claim("role_id", roleId.ToString()),
            new Claim("role_name", roleName)
        };
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_jwtKey));
        var token = new JwtSecurityToken(
            issuer: _issuer,
            audience: _audience,
            claims: claims,
            expires: DateTime.UtcNow.AddHours(_hours),
            signingCredentials: new SigningCredentials(key, SecurityAlgorithms.HmacSha256));
        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    private static string HashPassword(string password)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(password));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}

public sealed class AuthException : Exception
{
    public int StatusCode { get; }

    public AuthException(int statusCode, string message) : base(message) => StatusCode = statusCode;
}
