namespace ErpMobile.Api;

public sealed class LoginRequest
{
    public string Username { get; set; } = "";
    public string Password { get; set; } = "";
}

public sealed class LoginResponse
{
    public string Token { get; set; } = "";
    public string Username { get; set; } = "";
    public string FullName { get; set; } = "";
}

public sealed class ProjectItem
{
    public string ProjectCode { get; set; } = "";
    public string ProjectName { get; set; } = "";
}

public sealed class StockItem
{
    public int Import_ID { get; set; }
    public string Import_No { get; set; } = "";
    public DateTime? Import_Date { get; set; }
    public string Item_Name { get; set; } = "";
    public string Material { get; set; } = "";
    public string Size { get; set; } = "";
    public string UNIT { get; set; } = "";
    public decimal Qty_Import { get; set; }
    public decimal Qty_Exported { get; set; }
    public decimal Qty_Stock { get; set; }
    public decimal Weight_Stock { get; set; }
    public string QC_Code { get; set; } = "";
    public string QC_Status { get; set; } = "";
    public string Remarks { get; set; } = "";
    public string RIR_No { get; set; } = "";
    public string RIR_Status { get; set; } = "";
    public string Project_Code { get; set; } = "";
    public string PONo { get; set; } = "";
}

public sealed class StockResult
{
    public int Count { get; set; }
    public decimal QtyStock { get; set; }
    public decimal WeightStock { get; set; }
    public List<StockItem> Items { get; set; } = [];
}
